import Stripe from 'npm:stripe@19.1.0';
import { createClient } from 'npm:@supabase/supabase-js@2.57.4';
import { makeMembershipHandlers } from './membership-handlers.mjs';

export function membershipRuntime() {
  const env=(key:string)=>Deno.env.get(key) || '';
  const enabled=env('FPR_MEMBERSHIP_SANDBOX_ENABLED')==='true';
  // Deliberately no live-mode path in this release.
  const key=env('STRIPE_TEST_SECRET_KEY');
  const webhookSecret=env('STRIPE_TEST_WEBHOOK_SECRET');
  if(!enabled || !(/^(sk|rk)_test_/.test(key)) || !webhookSecret.startsWith('whsec_')) {
    const disabled=()=>new Response(JSON.stringify({error:'Membership testing is not configured.'}),{status:503,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
    return {api:disabled,webhook:disabled};
  }
  const stripe=new Stripe(key,{httpClient:Stripe.createFetchHttpClient(),maxNetworkRetries:1,timeout:15000});
  const db=createClient(env('SUPABASE_URL'),env('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});
  const auth=createClient(env('SUPABASE_URL'),env('SUPABASE_ANON_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});
  function checked<T>(result:{data:T,error:unknown}):T{if(result.error)throw Error('Database operation failed');return result.data;}
  const store={
    async claim(id:string,token:string){return checked(await db.rpc('claim_membership_billing',{p_user_id:id,p_token:token}));},
    async renew(id:string,token:string){checked(await db.from('membership_billing').update({lock_until:new Date(Date.now()+90000).toISOString()}).eq('user_id',id).eq('lock_token',token).gt('lock_until',new Date().toISOString()).select('user_id').single());},
    async release(id:string,token:string){checked(await db.from('membership_billing').update({lock_token:null,lock_until:null}).eq('user_id',id).eq('lock_token',token));},
    async get(id:string){return checked(await db.from('membership_billing').select('*').eq('user_id',id).single());},
    async byCustomer(id:string){return checked(await db.from('membership_billing').select('*').eq('customer_id',id).maybeSingle());},
    async setCustomer(id:string,token:string,customer:string){checked(await db.from('membership_billing').update({customer_id:customer}).eq('user_id',id).eq('lock_token',token).gt('lock_until',new Date().toISOString()).select('user_id').single());},
    async snapshot(id:string,token:string,value:{subscription_id:string|null,status:string,access_until:string|null,cancel_at_period_end:boolean}){
      checked(await db.rpc('save_membership_snapshot',{p_user_id:id,p_token:token,p_subscription_id:value.subscription_id,p_status:value.status,p_access_until:value.access_until,p_cancel_at_period_end:value.cancel_at_period_end}));
    }
  };
  return makeMembershipHandlers({stripe,store,config:{enabled,product:env('STRIPE_TEST_PRODUCT_ID'),prices:{monthly:env('STRIPE_TEST_MONTHLY_PRICE_ID'),yearly:env('STRIPE_TEST_YEARLY_PRICE_ID')},portalConfiguration:env('STRIPE_TEST_PORTAL_CONFIGURATION_ID') || undefined},
    async verifyUser(header:string){
      if(!header.startsWith('Bearer '))return null;
      const {data,error}=await auth.auth.getUser(header.slice(7));
      if(error || !data.user)return null;
      const scoped=createClient(env('SUPABASE_URL'),env('SUPABASE_ANON_KEY'),{global:{headers:{Authorization:header}},auth:{persistSession:false,autoRefreshToken:false}});
      const admin=await scoped.rpc('is_admin');
      // Sandbox controls are for verified FPR admins only, never members.
      return !admin.error && admin.data===true?data.user:null;
    },
    verifyEvent:(body:string,signature:string)=>stripe.webhooks.constructEventAsync(body,signature,webhookSecret,undefined,Stripe.createSubtleCryptoProvider())
  });
}
