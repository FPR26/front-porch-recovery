import Stripe from 'npm:stripe@19.1.0';
import { createClient } from 'npm:@supabase/supabase-js@2.57.4';
import { makeMembershipHandlers } from './membership-handlers.mjs';
import {readLiveMembershipConfig} from './membership-live-config.mjs';

export function membershipLiveRuntime() {
  const env=(key:string)=>Deno.env.get(key) || '';
  const settings=readLiveMembershipConfig(env);
  if(!settings.ready)return makeMembershipHandlers({stripe:null,store:null,config:{enabled:false,liveMode:true},verifyUser:async()=>null,verifyEvent:async()=>{throw Error('Disabled')}});
  const {key,webhookSecret}=settings;
  const stripe=new Stripe(key,{apiVersion:'2025-09-30.clover',httpClient:Stripe.createFetchHttpClient(),maxNetworkRetries:1,timeout:15000});
  const db=createClient(env('SUPABASE_URL'),env('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});
  const auth=createClient(env('SUPABASE_URL'),env('SUPABASE_ANON_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});
  function checked<T>(result:{data:T,error:unknown}):T{if(result.error)throw Error('Database operation failed');return result.data;}
  const store={
    async claim(id:string,token:string){return checked(await db.rpc('claim_membership_live_billing',{p_user_id:id,p_token:token}));},
    async renew(id:string,token:string){checked(await db.from('membership_live_billing').update({lock_until:new Date(Date.now()+90000).toISOString()}).eq('user_id',id).eq('lock_token',token).gt('lock_until',new Date().toISOString()).select('user_id').single());},
    async release(id:string,token:string){checked(await db.from('membership_live_billing').update({lock_token:null,lock_until:null}).eq('user_id',id).eq('lock_token',token));},
    async get(id:string){return checked(await db.from('membership_live_billing').select('*').eq('user_id',id).single());},
    async byCustomer(id:string){return checked(await db.from('membership_live_billing').select('*').eq('customer_id',id).maybeSingle());},
    async setCustomer(id:string,token:string,customer:string){checked(await db.from('membership_live_billing').update({customer_id:customer}).eq('user_id',id).eq('lock_token',token).gt('lock_until',new Date().toISOString()).select('user_id').single());},
    async snapshot(id:string,token:string,value:{subscription_id:string|null,status:string,access_until:string|null,cancel_at_period_end:boolean}){
      checked(await db.rpc('save_membership_live_snapshot',{p_user_id:id,p_token:token,p_subscription_id:value.subscription_id,p_status:value.status,p_access_until:value.access_until,p_cancel_at_period_end:value.cancel_at_period_end}));
    }
  };
  return makeMembershipHandlers({stripe,store,config:{enabled:true,liveMode:true,product:settings.product,prices:settings.prices,portalConfiguration:settings.portalConfiguration},
    async checkoutAllowed(){
      const flags=checked(await db.rpc('get_membership_live_launch_state')) as {checkout_enabled?:boolean,benefits_enabled?:boolean}|null;
      return flags?.checkout_enabled===true && flags?.benefits_enabled===true;
    },
    async verifyUser(header:string){
      if(!header.startsWith('Bearer '))return null;
      const {data,error}=await auth.auth.getUser(header.slice(7));
      if(error || !data.user)return null;
      // Production accepts confirmed FPR members, not the admin-only sandbox path.
      return data.user.email_confirmed_at?data.user:null;
    },
    verifyEvent:(body:string,signature:string)=>stripe.webhooks.constructEventAsync(body,signature,webhookSecret,undefined,Stripe.createSubtleCryptoProvider())
  });
}
