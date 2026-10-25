import {membershipLiveRuntime} from '../_shared/membership-live-runtime.ts';
const handlers=membershipLiveRuntime();
Deno.serve(handlers.webhook);
