import {createClient} from 'npm:@supabase/supabase-js@2.57.4';
import {makeSupporterCardHandler} from '../_shared/supporter-card-handler.mjs';
const url=Deno.env.get('SUPABASE_URL') || '';
const key=Deno.env.get('SUPABASE_ANON_KEY') || '';
Deno.serve(makeSupporterCardHandler({
 async verifyAccess(header:string){
  if(!header.startsWith('Bearer '))return null;
  const client=createClient(url,key,{global:{headers:{Authorization:header}},auth:{persistSession:false,autoRefreshToken:false}});
  const {data,error}=await client.auth.getUser(header.slice(7));
  if(error || !data.user)return null;
  const access=await client.rpc('get_my_supporter_benefits');
  if(access.error)throw Error('Access unavailable');
  return access.data;
 }
}));
