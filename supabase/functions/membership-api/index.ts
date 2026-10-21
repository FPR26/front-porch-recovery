import { membershipRuntime } from '../_shared/membership-runtime.ts';
const handlers=membershipRuntime();
Deno.serve(handlers.api);
