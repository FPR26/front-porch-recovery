// supabase/functions/submit-porch-story/index.ts
//
// Public submission endpoint for the Front Porch Recovery "Porch Story"
// form. This is the ONLY path that may write to public.porch_stories from
// outside the database — the browser never inserts directly (RLS on that
// table has no policy granting anon/authenticated INSERT; see schema.sql).
//
// Contract with supabase/schema.sql's submit_porch_story():
//   - status is always 'pending' on insert (hard-coded inside the SQL
//     function itself — not a parameter, so this function has no way to
//     set it to anything else even if it wanted to).
//   - reviewed_at / published_at / reviewed_by are not parameters of
//     submit_porch_story() at all. There is no code path here, or in the
//     SQL function, that can set them on submission.
//   - p_user_id is taken ONLY from a verified Supabase auth JWT, never
//     from the request body. A body-supplied user_id/userId field is
//     read nowhere below and has no effect.
//   - submit_porch_story() is callable only by the service_role (see the
//     revoke/grant block at the bottom of schema.sql). The service-role
//     key lives only in this Edge Function's server-side environment
//     (Deno.env), which Supabase injects automatically — it is never
//     sent to, or readable from, the browser.
//
// Auth model:
//   verify_jwt is enabled for this function at the platform/gateway level
//   (see the deploy call), so the gateway already rejects any request
//   whose Authorization header is not a validly-signed Supabase JWT
//   before this code even runs. That covers "is this request carrying a
//   legitimate Supabase key or session token at all" — both the
//   project's anon JWT (for anonymous submissions) and a real user's
//   access token (for signed-in submissions) satisfy it.
//
//   What the gateway's check does NOT tell us is *which* of those two
//   cases we're in, because the anon key and a user access token are
//   both just "a validly-signed JWT" to it. So this function makes that
//   distinction itself: it takes the same bearer token and asks Supabase
//   Auth to resolve it to a real user via auth.getUser(token). The
//   project's anon JWT has no corresponding auth.users row, so that call
//   fails for it and we fall back to an anonymous submission (p_user_id
//   = null). A real, unexpired user access token resolves to that user's
//   id, which is what gets passed to submit_porch_story() as p_user_id.
//   There is no other way for p_user_id to become non-null.
//
// Rate limiting:
//   See `checkRateLimit()` below — a real, working per-IP limiter, with
//   an explicit comment on its one real limitation (in-memory state does
//   not survive a cold isolate). supabase/README.md documents the
//   upgrade path (a Postgres-backed counter, or Upstash Redis) if this
//   ever needs to be durable across isolates.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

// Exact production origin only — not '*'. GitHub Pages' Origin header for
// this site is scheme+host only (no path), so the project path
// (/front-porch-recovery/) does not appear here.
const ALLOWED_ORIGIN = 'https://fpr26.github.io';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': ALLOWED_ORIGIN,
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Vary': 'Origin',
};

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

// Generous upper bound on the raw request body. The real per-field limits
// (80 / 120 / 8000 / 254 chars) cap this far lower in practice; this is
// just a cheap first line of defense against someone sending a huge body
// before any JSON parsing happens.
const MAX_BODY_BYTES = 50_000;

const ALLOWED_CATEGORIES = new Set([
  'Recovery', 'Mental health', 'Rebuilding life', 'Relationships',
  'Grief / loss', 'Trauma / healing', 'Milestones', 'Hope', 'Humor', 'Other',
]);

// ---------- rate limiting ----------
// Real, functioning per-IP sliding-window limiter — NOT a no-op. Its one
// honest limitation: the Map lives in this isolate's memory, and Supabase
// may route a given invocation to a fresh isolate (especially after a
// period with no traffic), so the window can reset more often than the
// numbers below suggest. That's a real but partial protection, which is
// why it's documented here and in supabase/README.md rather than
// presented as a hard guarantee. If FPR ever needs a durable limit across
// isolates/regions, swap this function's body for a lookup against a
// small Postgres table (e.g. a submit_attempts(ip, window_start, count)
// row upserted with an atomic UPDATE ... RETURNING) or an Upstash Redis
// call — the call site below (`checkRateLimit(ip)`) doesn't need to
// change.
const RATE_LIMIT_WINDOW_MS = 10 * 60 * 1000; // 10 minutes
const RATE_LIMIT_MAX = 5; // submissions per IP per window
const rateLimitState = new Map<string, { windowStart: number; count: number }>();

function checkRateLimit(ip: string): boolean {
  const now = Date.now();
  const entry = rateLimitState.get(ip);
  if (!entry || now - entry.windowStart > RATE_LIMIT_WINDOW_MS) {
    rateLimitState.set(ip, { windowStart: now, count: 1 });
    return true;
  }
  if (entry.count >= RATE_LIMIT_MAX) return false;
  entry.count += 1;
  return true;
}

function clientIp(req: Request): string {
  // Supabase's edge infra sets x-forwarded-for; best-effort only.
  const fwd = req.headers.get('x-forwarded-for');
  if (fwd) return fwd.split(',')[0].trim();
  return 'unknown';
}

// ---------- validation ----------
type ValidatedFields = {
  display_name: string;
  title: string;
  category: string;
  story_body: string;
  contact_email: string | null;
  publishing_permission: boolean;
};

function validate(body: unknown): { ok: true; fields: ValidatedFields } | { ok: false; error: string } {
  if (typeof body !== 'object' || body === null) {
    return { ok: false, error: 'Request body must be a JSON object.' };
  }
  const b = body as Record<string, unknown>;

  const displayName = typeof b.display_name === 'string' ? b.display_name.trim() : '';
  const title = typeof b.title === 'string' ? b.title.trim() : '';
  const category = typeof b.category === 'string' ? b.category.trim() : '';
  const storyBody = typeof b.story_body === 'string' ? b.story_body.trim() : '';
  const contactEmailRaw = typeof b.contact_email === 'string' ? b.contact_email.trim() : '';

  // publishing_permission must be the literal boolean true — a missing
  // field, a string "true", or anything else is rejected here with a
  // clear 400 rather than falling through to the database, where
  // submit_porch_story() would raise a 23514 check_violation for the
  // same reason. Both layers enforce the identical rule independently.
  const publishingPermission = b.publishing_permission === true;

  if (!displayName) return { ok: false, error: 'display_name is required.' };
  if (displayName.length > 80) return { ok: false, error: 'display_name must be 80 characters or fewer.' };

  if (!title) return { ok: false, error: 'title is required.' };
  if (title.length > 120) return { ok: false, error: 'title must be 120 characters or fewer.' };

  if (!category) return { ok: false, error: 'category is required.' };
  if (!ALLOWED_CATEGORIES.has(category)) return { ok: false, error: 'category is not one of the allowed values.' };

  if (!storyBody) return { ok: false, error: 'story_body is required.' };
  if (storyBody.length > 8000) return { ok: false, error: 'story_body must be 8,000 characters or fewer.' };

  if (contactEmailRaw) {
    if (contactEmailRaw.length > 254) return { ok: false, error: 'contact_email must be 254 characters or fewer.' };
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(contactEmailRaw)) {
      return { ok: false, error: 'contact_email is not a valid email address.' };
    }
  }

  if (b.publishing_permission === undefined) {
    return { ok: false, error: 'publishing_permission is required.' };
  }
  if (!publishingPermission) {
    return { ok: false, error: 'Publishing permission is required to submit a Porch Story.' };
  }

  return {
    ok: true,
    fields: {
      display_name: displayName,
      title,
      category,
      story_body: storyBody,
      contact_email: contactEmailRaw || null,
      publishing_permission: publishingPermission,
    },
  };
}

// ---------- main handler ----------
Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== 'POST') {
    return jsonResponse({ ok: false, error: 'Method not allowed.' }, 405);
  }

  const ip = clientIp(req);
  if (!checkRateLimit(ip)) {
    return jsonResponse({ ok: false, error: 'Too many submissions. Please try again later.' }, 429);
  }

  const contentLengthHeader = req.headers.get('content-length');
  if (contentLengthHeader && Number(contentLengthHeader) > MAX_BODY_BYTES) {
    return jsonResponse({ ok: false, error: 'Request body too large.' }, 413);
  }

  let rawBody: string;
  try {
    rawBody = await req.text();
  } catch {
    return jsonResponse({ ok: false, error: 'Could not read request body.' }, 400);
  }
  if (rawBody.length > MAX_BODY_BYTES) {
    return jsonResponse({ ok: false, error: 'Request body too large.' }, 413);
  }

  let parsedBody: unknown;
  try {
    parsedBody = JSON.parse(rawBody);
  } catch {
    return jsonResponse({ ok: false, error: 'Request body must be valid JSON.' }, 400);
  }

  const validated = validate(parsedBody);
  if (!validated.ok) {
    return jsonResponse({ ok: false, error: validated.error }, 400);
  }

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
  // Prefer the legacy service_role JWT (present on every Supabase project
  // regardless of whether the new-format keys have been adopted). Fall
  // back to the new secret-key map only if that legacy key is ever
  // deactivated.
  const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
    ?? (() => {
      try {
        const secrets = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}');
        return secrets.default ?? '';
      } catch {
        return '';
      }
    })();

  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    console.error('submit-porch-story: missing SUPABASE_URL or a service-role/secret key in the function environment.');
    return jsonResponse({ ok: false, error: 'Server misconfiguration.' }, 500);
  }

  // Derive the verified user id (or null) from the Authorization header.
  // This is the ONLY source of user_id used below. Nothing from the
  // request body is ever consulted for this.
  let verifiedUserId: string | null = null;
  const authHeader = req.headers.get('authorization') ?? req.headers.get('Authorization');
  if (authHeader && authHeader.toLowerCase().startsWith('bearer ')) {
    const token = authHeader.slice(7).trim();
    if (token) {
      try {
        const authClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
        const { data, error } = await authClient.auth.getUser(token);
        if (!error && data?.user?.id) {
          verifiedUserId = data.user.id;
        }
      } catch (err) {
        console.error('submit-porch-story: auth.getUser failed', err);
        // Fail closed to anonymous, not open to trusting anything from
        // the request — verifiedUserId stays null.
      }
    }
  }

  const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const { data: newId, error: rpcError } = await supabaseAdmin.rpc('submit_porch_story', {
    p_display_name: validated.fields.display_name,
    p_title: validated.fields.title,
    p_category: validated.fields.category,
    p_story_body: validated.fields.story_body,
    p_publishing_permission: validated.fields.publishing_permission,
    p_user_id: verifiedUserId,
    p_contact_email: validated.fields.contact_email,
  });

  if (rpcError) {
    // 23514 = check_violation. submit_porch_story() raises this itself
    // for publishing_permission (already caught above, but kept here as
    // defense-in-depth), and the table's own CHECK constraints raise the
    // same code for category/length violations the validate() step
    // above should already have caught. Either way, surface it as a
    // clean 400 rather than a generic 500.
    if (rpcError.code === '23514') {
      return jsonResponse({ ok: false, error: 'Submission failed validation.' }, 400);
    }
    console.error('submit-porch-story: rpc error', rpcError);
    return jsonResponse({ ok: false, error: 'Something went wrong saving that story.' }, 500);
  }

  return jsonResponse({ ok: true, id: newId }, 200);
});

