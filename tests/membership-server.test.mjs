import {test} from 'node:test';
import assert from 'node:assert/strict';
import {makeMembershipHandlers} from '../supabase/functions/_shared/membership-handlers.mjs';
const config={enabled:true,product:'prod_test',prices:{monthly:'price_month',yearly:'price_year'}};
function fixture(){
  const rows=new Map(),locks=new Set(),sessions=[],subs=[];let calls=0,serial=0,validSignature=true;
  const store={async claim(id,token){if(locks.has(id))return false;locks.add(id);if(!rows.has(id))rows.set(id,{user_id:id,customer_id:null});return true},async renew(id){if(!locks.has(id))throw Error("Expired lock")},async release(id){locks.delete(id)},async get(id){return rows.get(id)},async setCustomer(id,token,customer){rows.get(id).customer_id=customer},async byCustomer(c){return [...rows.values()].find(r=>r.customer_id===c)},async snapshot(id,token,data){Object.assign(rows.get(id),data)}};
  const stripe={prices:{async retrieve(id){return {id,active:true,livemode:false,currency:'usd',unit_amount:id==='price_month'?300:2500,recurring:{interval:id==='price_month'?'month':'year',interval_count:1},product:'prod_test'}}},customers:{async create(data){calls++;return {id:'cus_'+data.metadata.fpr_user_id}}},subscriptions:{async list(){return {data:subs,has_more:false}}},checkout:{sessions:{async list({customer}){return {data:sessions.filter(s=>s.customer===customer&&s.status==='open'),has_more:false}},async expire(id){sessions.find(s=>s.id===id).status='expired'},async create(data){const row={...data,id:'cs_'+(++serial),status:'open',url:'https://checkout.stripe.com/test'};sessions.push(row);return row}}},billingPortal:{sessions:{async create(data){return {url:'https://billing.stripe.com/test',...data}}}}};
  const handlers=makeMembershipHandlers({stripe,store,config:{...config},uuid:()=>String(++serial),now:()=>1000000,verifyUser:async h=>h==='Bearer admin-A'?{id:'A'}:h==='Bearer admin-B'?{id:'B'}:null,verifyEvent:async (body,sig)=>{if(sig!=='valid')throw Error('Bad signature');return JSON.parse(body)}});
  const req=(body,token='admin-A',origin='https://fpr26.github.io')=>new Request('https://example.test',{method:'POST',headers:{authorization:'Bearer '+token,origin,'content-type':'application/json'},body:JSON.stringify(body)});
  const event=(object,type='customer.subscription.updated',extra={})=>new Request('https://example.test',{method:'POST',headers:{'stripe-signature':'valid'},body:JSON.stringify({type,livemode:false,data:{object},...extra})});
  return {...handlers,rows,locks,sessions,subs,stripe,req,event,store};
}
test('unauthenticated/nonadmin, cross-origin and invalid plan requests are rejected',async()=>{
 const f=fixture();assert.equal((await f.api(f.req({action:'checkout',plan:'monthly'},'member'))).status,401);assert.equal((await f.api(f.req({action:'checkout',plan:'monthly'},'admin-A','https://evil.test'))).status,403);assert.equal((await f.api(f.req({action:'checkout',plan:'cheap',price:'evil'}))).status,400);assert.equal(f.rows.size,0);
});
test('checkout fixes identity, allowed price, URLs and subscription mode on server; reuses open checkout',async()=>{
 const f=fixture();await f.api(f.req({action:'checkout',plan:'monthly',user_id:'B',customer:'cus_B',success_url:'https://evil.test'}));assert.equal(f.sessions.length,1);const s=f.sessions[0];assert.equal(s.customer,'cus_A');assert.equal(s.mode,'subscription');assert.equal(s.line_items[0].price,'price_month');assert.match(s.success_url,/^https:\/\/fpr26.github.io\//);await f.api(f.req({action:'checkout',plan:'monthly'}));assert.equal(f.sessions.length,1);assert.equal(f.rows.get('A').status,'none');
});
test('yearly change expires prior app checkout and uses approved $25 price',async()=>{const f=fixture();await f.api(f.req({action:'checkout',plan:'monthly'}));await f.api(f.req({action:'checkout',plan:'yearly'}));assert.equal(f.sessions[0].status,'expired');assert.equal(f.sessions[1].line_items[0].price,'price_year');});
test('price mismatch and locked concurrent request fail closed',async()=>{const f=fixture();f.stripe.prices.retrieve=async()=>({livemode:true});assert.equal((await f.api(f.req({action:'checkout',plan:'monthly'}))).status,503);assert.equal(f.sessions.length,0);f.locks.add('A');assert.equal((await f.api(f.req({action:'checkout',plan:'monthly'}))).status,409);});
function paid(){return {id:'sub_A',created:1,livemode:false,status:'active',customer:'cus_A',cancel_at_period_end:true,latest_invoice:{status:'paid'},items:{data:[{price:{id:'price_month'},current_period_end:2000}]}}}
test('signed webhooks fetch canonical Stripe state; retries/out-of-order payloads cannot regrant canceled access',async()=>{const f=fixture();await f.api(f.req({action:'checkout',plan:'monthly'}));f.subs.push(paid());assert.equal((await f.webhook(f.event({customer:'cus_A',status:'canceled'}))).status,200);assert.equal(f.rows.get('A').status,'active');assert.equal(f.rows.get('A').cancel_at_period_end,true);f.subs[0].status='canceled';await f.webhook(f.event({customer:'cus_A',status:'active'}));await f.webhook(f.event({customer:'cus_A',status:'active'}));assert.equal(f.rows.get('A').status,'canceled');assert.equal(f.rows.get('A').access_until,null);});
test('signature, mode and unknown customer checks',async()=>{const f=fixture();assert.equal((await f.webhook(new Request('https://x',{method:'POST',body:'{}'}))).status,400);assert.equal((await f.webhook(f.event({customer:'cus_A'},undefined,{livemode:true}))).status,400);assert.equal((await f.webhook(f.event({customer:'unknown'}))).status,200);assert.equal(f.rows.size,0);});
test('expired, unpaid and unapproved-price subscriptions never grant access; existing subscription blocks duplicate purchase',async()=>{for(const mutation of [s=>s.latest_invoice.status='open',s=>s.items.data[0].current_period_end=500,s=>s.items.data[0].price.id='other']){const f=fixture();await f.api(f.req({action:'checkout',plan:'monthly'}));const s=paid();mutation(s);f.subs.push(s);await f.webhook(f.event({customer:'cus_A'}));assert.equal(f.rows.get('A').access_until,null);assert.equal((await f.api(f.req({action:'checkout',plan:'monthly'}))).status,409);}});
test('portal uses only the verified user customer; return redirect alone grants nothing',async()=>{const f=fixture();assert.equal((await f.api(f.req({action:'portal',customer:'cus_A'},'admin-B'))).status,409);await f.api(f.req({action:'checkout',plan:'monthly'}));assert.equal((await f.api(f.req({action:'portal',customer:'cus_B'}))).status,200);assert.equal(f.rows.get('A').access_until,null);});

test('flexible billing cancellation date sets the UI flag while keeping paid access',async()=>{
 const f=fixture();await f.api(f.req({action:'checkout',plan:'monthly'}));const s=paid();s.cancel_at_period_end=false;s.cancel_at=2000;f.subs.push(s);
 await f.webhook(f.event({customer:'cus_A'}));assert.equal(f.rows.get('A').cancel_at_period_end,true);assert.equal(f.rows.get('A').access_until,new Date(2000000).toISOString());
 // Undoing cancellation clears the flag, including after an old event replay.
 s.cancel_at=null;await f.webhook(f.event({customer:'cus_A',cancel_at:2000}));assert.equal(f.rows.get('A').cancel_at_period_end,false);
});
test('custom cancellation caps access; a past cancellation cannot retain access',async()=>{
 const f=fixture();await f.api(f.req({action:'checkout',plan:'monthly'}));const s=paid();s.cancel_at_period_end=false;s.cancel_at=1500;f.subs.push(s);
 await f.api(f.req({action:'sync'}));assert.equal(f.rows.get('A').access_until,new Date(1500000).toISOString());assert.equal(f.rows.get('A').cancel_at_period_end,true);
 s.cancel_at=900;await f.api(f.req({action:'sync'}));assert.equal(f.rows.get('A').access_until,null);assert.notEqual(f.rows.get('A').status,'active');
});
test('normal renewals and invalid cancellation dates do not show cancellation',async()=>{
 for(const date of [null,undefined,0,'2000',NaN]){const f=fixture();await f.api(f.req({action:'checkout',plan:'monthly'}));const s=paid();s.cancel_at_period_end=false;s.cancel_at=date;f.subs.push(s);await f.api(f.req({action:'sync'}));assert.equal(f.rows.get('A').cancel_at_period_end,false);assert.equal(f.rows.get('A').status,'active');}
});
