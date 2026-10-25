import {test} from 'node:test';import assert from 'node:assert/strict';
import {makeMembershipHandlers} from '../supabase/functions/_shared/membership-handlers.mjs';
import {readLiveMembershipConfig} from '../supabase/functions/_shared/membership-live-config.mjs';
const config={enabled:true,liveMode:true,product:'prod_test',prices:{monthly:'price_month',yearly:'price_year'}};
function fixture(options={}){
  const rows=new Map(),locks=new Set(),sessions=[],subs=[];let calls=0,serial=0,validSignature=true;
  const store={async claim(id,token){if(locks.has(id))return false;locks.add(id);if(!rows.has(id))rows.set(id,{user_id:id,customer_id:null});return true},async renew(id){if(!locks.has(id))throw Error("Expired lock")},async release(id){locks.delete(id)},async get(id){return rows.get(id)},async setCustomer(id,token,customer){rows.get(id).customer_id=customer},async byCustomer(c){return [...rows.values()].find(r=>r.customer_id===c)},async snapshot(id,token,data){Object.assign(rows.get(id),data)}};
  const stripe={prices:{async retrieve(id){return {id,active:true,livemode:true,currency:'usd',unit_amount:id==='price_month'?300:2500,recurring:{interval:id==='price_month'?'month':'year',interval_count:1,usage_type:'licensed'},product:'prod_test'}}},customers:{async create(data){calls++;return {id:'cus_'+data.metadata.fpr_user_id,livemode:true}}},subscriptions:{async list(){return {data:subs,has_more:false}}},checkout:{sessions:{async list({customer}){return {data:sessions.filter(s=>s.customer===customer&&s.status==='open'),has_more:false}},async expire(id){sessions.find(s=>s.id===id).status='expired'},async create(data){const row={...data,id:'cs_'+(++serial),livemode:true,status:'open',url:'https://checkout.stripe.com/test'};sessions.push(row);return row}}},billingPortal:{sessions:{async create(data){return {url:'https://billing.stripe.com/test',...data}}}}};
  const handlers=makeMembershipHandlers({stripe,store,config:{...config},report:()=>{},...options,uuid:()=>String(++serial),now:()=>1000000,verifyUser:async h=>h==='Bearer member-A'?{id:'A'}:h==='Bearer member-B'?{id:'B'}:null,verifyEvent:async (body,sig)=>{if(sig!=='valid')throw Error('Bad signature');return JSON.parse(body)}});
  const req=(body,token='member-A',origin='https://fpr26.github.io')=>new Request('https://example.test',{method:'POST',headers:{authorization:'Bearer '+token,origin,'content-type':'application/json'},body:JSON.stringify(body)});
  const event=(object,type='customer.subscription.updated',extra={})=>new Request('https://example.test',{method:'POST',headers:{'stripe-signature':'valid'},body:JSON.stringify({type,livemode:true,data:{object},...extra})});
  return {...handlers,rows,locks,sessions,subs,stripe,req,event,store};
}

function paid(){return {id:'sub_A',created:1,livemode:true,status:'active',customer:'cus_A',cancel_at_period_end:false,latest_invoice:{id:'in_A',livemode:true,currency:'usd',status:'paid',parent:{subscription_details:{subscription:'sub_A'}},lines:{has_more:false,data:[{amount:300,parent:{subscription_item_details:{subscription_item:'si_A'}},pricing:{price_details:{price:'price_month'}},period:{start:900,end:2000}}]}},items:{data:[{id:'si_A',quantity:1,price:{id:'price_month',livemode:true,product:'prod_test',currency:'usd',unit_amount:300,recurring:{interval:'month',interval_count:1,usage_type:'licensed'}},current_period_end:2000}]}}}

test('production configuration requires explicit enablement and live-only complete credentials',()=>{
 const env={FPR_MEMBERSHIP_LIVE_ENABLED:'true',STRIPE_LIVE_SECRET_KEY:'rk_live_fixture',STRIPE_LIVE_WEBHOOK_SECRET:'whsec_fixture',STRIPE_LIVE_PRODUCT_ID:'prod_fixture',STRIPE_LIVE_MONTHLY_PRICE_ID:'price_month',STRIPE_LIVE_YEARLY_PRICE_ID:'price_year',STRIPE_LIVE_PORTAL_CONFIGURATION_ID:'bpc_fixture'};
 assert.equal(readLiveMembershipConfig(k=>env[k]||'').ready,true);
 for(const change of [{FPR_MEMBERSHIP_LIVE_ENABLED:''},{FPR_MEMBERSHIP_LIVE_ENABLED:'TRUE'},{STRIPE_LIVE_SECRET_KEY:'rk_test_fixture'},{STRIPE_LIVE_PORTAL_CONFIGURATION_ID:''},{STRIPE_LIVE_YEARLY_PRICE_ID:'price_month'}])assert.equal(readLiveMembershipConfig(k=>({...env,...change})[k]||'').ready,false);
});
test('closed checkout refuses purchase before customer creation; existing member management remains available',async()=>{
 let open=false;const f=fixture({checkoutAllowed:async()=>open});
 assert.equal((await f.api(f.req({action:'checkout',plan:'monthly'}))).status,409);assert.equal(f.rows.size,0);
 let state=await(await f.api(new Request('https://example.test'))).json();assert.equal(state.checkout_open,false);assert.equal(state.service_ready,true);
 open=true;await f.api(f.req({action:'checkout',plan:'monthly'}));open=false;
 assert.equal((await f.api(f.req({action:'portal'}))).status,200);assert.equal((await f.api(f.req({action:'sync'}))).status,200);
});
test('production disabled means no service and no available checkout',async()=>{
 const f=fixture({config:{...config,enabled:false}});const response=await f.api(new Request('https://example.test'));assert.deepEqual(await response.json(),{sandbox:false,service_ready:false,checkout_open:false});
 assert.equal((await f.api(f.req({action:'checkout',plan:'monthly'}))).status,503);assert.equal((await f.webhook(f.event({customer:'cus_A'}))).status,503);assert.equal(f.rows.size,0);
});
test('production checkout fixes plan, identity and price and rejects test-mode prices',async()=>{
 const f=fixture();const result=await(await f.api(f.req({action:'checkout',plan:'monthly',customer:'other',user_id:'B',success_url:'https://other.invalid'}))).json();
 assert.equal(result.sandbox,false);assert.equal(f.sessions[0].customer,'cus_A');assert.equal(f.sessions[0].line_items[0].price,'price_month');assert.equal(f.sessions[0].metadata.fpr_mode,'live');assert(f.sessions[0].success_url.startsWith('https://fpr26.github.io/'));
 await f.api(f.req({action:'checkout',plan:'yearly'}));assert.equal(f.sessions[1].line_items[0].price,'price_year');
 const bad=fixture();const retrieve=bad.stripe.prices.retrieve;bad.stripe.prices.retrieve=async id=>({...await retrieve(id),livemode:false});assert.equal((await bad.api(bad.req({action:'checkout',plan:'monthly'}))).status,503);assert.equal(bad.sessions.length,0);
});
test('live endpoint rejects sandbox events and canonical sandbox objects',async()=>{
 const f=fixture();await f.api(f.req({action:'checkout',plan:'monthly'}));assert.equal((await f.webhook(f.event({customer:'cus_A'},undefined,{livemode:false}))).status,400);
 const s=paid();s.livemode=false;f.subs.push(s);assert.equal((await f.webhook(f.event({customer:'cus_A'}))).status,503);assert.equal(f.rows.get('A').access_until,null);
});
test('paid access is capped by paid invoice coverage and scheduled cancellation',async()=>{
 const f=fixture();await f.api(f.req({action:'checkout',plan:'monthly'}));const s=paid();s.latest_invoice.lines.data[0].period.end=1800;s.cancel_at=1700;f.subs.push(s);
 assert.equal((await f.webhook(f.event({customer:'cus_A'}))).status,200);assert.equal(f.rows.get('A').access_until,new Date(1700000).toISOString());assert.equal(f.rows.get('A').cancel_at_period_end,true);
 s.status='canceled';await f.webhook(f.event({customer:'cus_A',status:'active'}));assert.equal(f.rows.get('A').access_until,null);assert.equal(f.rows.get('A').status,'canceled');
});
test('old/unpaid/wrong-subscription/wrong-item invoices and quantity changes cannot grant live access',async()=>{
 for(const mutate of [s=>s.latest_invoice.lines.data[0].period.end=999,s=>s.latest_invoice.status='open',s=>s.latest_invoice.parent.subscription_details.subscription='other',s=>s.latest_invoice.lines.data[0].parent.subscription_item_details.subscription_item='other',s=>s.latest_invoice.livemode=false,s=>s.items.data[0].quantity=2,s=>s.latest_invoice.lines.data[0].amount=0,s=>s.items.data[0].price.currency='eur',s=>s.items.data[0].price.unit_amount=999,s=>s.items.data[0].price.product='other',s=>s.items.data[0].price.recurring.usage_type='metered']){
  const f=fixture();await f.api(f.req({action:'checkout',plan:'monthly'}));const s=paid();mutate(s);f.subs.push(s);await f.webhook(f.event({customer:'cus_A'}));assert.equal(f.rows.get('A').access_until,null);
 }
});
test('truncated invoice line expansion is reread and still-too-large invoices stay retryable',async()=>{
 const f=fixture();await f.api(f.req({action:'checkout',plan:'monthly'}));const s=paid(),lines=s.latest_invoice.lines;s.latest_invoice.lines={has_more:true,data:[]};f.subs.push(s);f.stripe.invoices={listLineItems:async()=>lines};
 assert.equal((await f.webhook(f.event({customer:'cus_A'}))).status,200);assert.equal(f.rows.get('A').status,'active');
 s.latest_invoice.lines={has_more:true,data:[]};f.stripe.invoices.listLineItems=async()=>({has_more:true,data:[]});assert.equal((await f.webhook(f.event({customer:'cus_A'}))).status,503);
});

test('closing the checkout gate during preparation prevents new session creation',async()=>{
 let checks=0;const f=fixture({checkoutAllowed:async()=>++checks<3});
 assert.equal((await f.api(f.req({action:'checkout',plan:'monthly'}))).status,409);assert.equal(f.sessions.length,0);
});
test('live customer and checkout idempotency keys have their own namespace',async()=>{
 const f=fixture(),keys=[];f.stripe.customers.create=async(_body,options)=>{keys.push(options.idempotencyKey);return {id:'cus_A',livemode:true}};
 const create=f.stripe.checkout.sessions.create;f.stripe.checkout.sessions.create=async(body,options)=>{keys.push(options.idempotencyKey);return create(body)};
 await f.api(f.req({action:'checkout',plan:'monthly'}));assert(keys.every(key=>key.startsWith('fpr-live-')));assert.equal(keys.length,2);
});

test('customer binding, paused state and failed renewal never retain paid access',async()=>{
 const f=fixture();await f.api(f.req({action:'checkout',plan:'monthly'}));const s=paid();f.subs.push(s);await f.webhook(f.event({customer:'cus_A'}));assert.equal(f.rows.get('A').status,'active');
 s.status='paused';await f.webhook(f.event({customer:'cus_A'},'customer.subscription.paused'));assert.equal(f.rows.get('A').access_until,null);
 s.status='active';s.latest_invoice.status='open';await f.webhook(f.event({customer:'cus_A'},'invoice.payment_failed'));assert.equal(f.rows.get('A').access_until,null);
 s.latest_invoice.status='paid';s.customer='cus_other';assert.equal((await f.webhook(f.event({customer:'cus_A'}))).status,503);
});
test('annual approved invoice grants only its covered period and account credits are allowed',async()=>{
 const f=fixture();await f.api(f.req({action:'checkout',plan:'yearly'}));const s=paid();s.items.data[0].price.id='price_year';s.items.data[0].price.unit_amount=2500;s.items.data[0].price.recurring.interval='year';s.items.data[0].current_period_end=32000000;s.latest_invoice.lines.data[0].pricing.price_details.price='price_year';s.latest_invoice.lines.data[0].amount=2500;s.latest_invoice.lines.data[0].period.end=32000000;s.latest_invoice.amount_paid=0;f.subs.push(s);
 await f.webhook(f.event({customer:'cus_A'}));assert.equal(f.rows.get('A').access_until,new Date(32000000000).toISOString());
});

test('production availability supports browser GET preflight and never exposes configuration',async()=>{
 const f=fixture({checkoutAllowed:async()=>false});const preflight=await f.api(new Request('https://example.test',{method:'OPTIONS',headers:{origin:'https://fpr26.github.io','access-control-request-method':'GET'}}));
 assert.equal(preflight.status,204);assert(preflight.headers.get('access-control-allow-methods').includes('GET'));
 const response=await f.api(new Request('https://example.test',{headers:{origin:'https://fpr26.github.io'}}));assert.equal(response.headers.get('access-control-allow-origin'),'https://fpr26.github.io');assert.deepEqual(await response.json(),{sandbox:false,service_ready:true,checkout_open:false});
});
