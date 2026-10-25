import {parseHTML} from 'npm:linkedom@0.18.12';import fs from 'node:fs';import assert from 'node:assert/strict';
const html=fs.readFileSync(new URL('../index.html',import.meta.url),'utf8'),start=html.indexOf('(function initProductionMembership(){'),code=html.slice(start,html.indexOf('})();',start)+5);
const tick=()=>new Promise(resolve=>setTimeout(resolve,10));
function fixture({user='A',ready=false,open=false,active=true,member={sandbox:false,status:'none',has_customer:false,has_access:false}}={}){
 const {window}=parseHTML(html),{document}=window;if(active)document.getElementById('page-supporter').classList.add('active');else document.getElementById('page-supporter').classList.remove('active');
 let identity=user,onAuth,invoke=async options=>({data:options.method==='GET'?{sandbox:false,service_ready:ready,checkout_open:open}:{sandbox:false,updated:true,url:'https://checkout.stripe.com/live-fixture'}});const calls=[],redirects=[];
 const client={auth:{getSession:async()=>({data:{session:identity?{user:{id:identity}}:null}}),onAuthStateChange:fn=>onAuth=fn},rpc:async name=>{calls.push(name);return {data:member}},functions:{invoke:async(name,options)=>{calls.push({name,options});return await invoke(options)}}};
 window.__fprSupabaseClient=client;window.location={assign:url=>redirects.push(url)};
 new Function('window','document','CustomEvent','setTimeout','URL',code)(window,document,window.CustomEvent,setTimeout,URL);
 return {document,calls,redirects,refresh:()=>document.dispatchEvent(new window.CustomEvent('fpr:pagechange',{detail:{page:'supporter'}})),setInvoke:fn=>invoke=fn,signout(){identity=null;onAuth('SIGNED_OUT',null)}};
}
Deno.test('production UI and purchase buttons remain hidden when processing or checkout is closed',async()=>{
 const disabled=fixture();await tick();assert.equal(disabled.document.getElementById('supporter-live-membership').hidden,true);assert.equal(disabled.calls.filter(c=>typeof c==='string').length,0);
 assert.match(disabled.document.getElementById('supporter-payment-state').textContent,/payments are not open/);
 const closed=fixture({ready:true,open:false});await tick();assert.equal(closed.document.getElementById('supporter-live-membership').hidden,true);
});
Deno.test('open signup requires sign-in and shows the recurring approved prices',async()=>{
 const f=fixture({user:null,ready:true,open:true});await tick();assert.equal(f.document.getElementById('supporter-live-membership').hidden,false);assert.equal(f.document.getElementById('supporter-live-signin').hidden,false);
 const buttons=f.document.querySelectorAll('[data-live-action="checkout"]');assert.equal(buttons.length,2);assert([...buttons].every(b=>b.disabled));assert.equal(f.document.getElementById('supporter-price-label').textContent,'Membership: $3/month or $25/year.');
});
Deno.test('existing paid members retain portal and refresh controls after new sales close',async()=>{
 const f=fixture({ready:true,open:false,member:{sandbox:false,status:'active',has_customer:true,has_access:true,access_until:'2027-01-01T00:00:00Z',cancel_at_period_end:true}});await tick();
 assert.equal(f.document.getElementById('supporter-live-membership').hidden,false);assert.equal(f.document.querySelector('[data-live-action="portal"]').hidden,false);assert.equal(f.document.querySelector('[data-live-action="checkout"]').hidden,true);assert.equal(f.document.getElementById('account-paid-membership-open').hidden,false);assert.match(f.document.getElementById('supporter-live-status').textContent,/Cancellation is scheduled/);
});
Deno.test('real checkout redirects only for explicit production responses and official HTTPS URLs',async()=>{
 const f=fixture({ready:true,open:true});await tick();f.setInvoke(async()=>({data:{sandbox:true,url:'https://checkout.stripe.com/test'}}));f.document.querySelector('[data-live-action="checkout"]').click();await tick();assert.equal(f.redirects.length,0);
 f.setInvoke(async()=>({data:{sandbox:false,url:'https://other.invalid'}}));f.document.querySelector('[data-live-action="checkout"]').click();await tick();assert.equal(f.redirects.length,0);
 f.setInvoke(async()=>({data:{sandbox:false,url:'https://checkout.stripe.com/live-fixture'}}));f.document.querySelector('[data-live-action="checkout"]').click();await tick();assert.deepEqual(f.redirects,['https://checkout.stripe.com/live-fixture']);
});
Deno.test('sign-out suppresses pending live redirect and hides prior member management',async()=>{
 const f=fixture({ready:true,open:true});await tick();let resolve;f.setInvoke(options=>options.method==='GET'?Promise.resolve({data:{sandbox:false,service_ready:false,checkout_open:false}}):new Promise(r=>resolve=r));f.document.querySelector('[data-live-action="checkout"]').click();f.signout();resolve({data:{sandbox:false,url:'https://checkout.stripe.com/live-fixture'}});await tick();assert.equal(f.redirects.length,0);assert.equal(f.document.getElementById('account-paid-membership-open').hidden,true);
});

Deno.test('Account can find existing paid membership from other pages without calling Stripe sync',async()=>{
 const f=fixture({ready:true,open:false,active:false,member:{sandbox:false,status:'active',has_customer:true,has_access:true,access_until:'2027-01-01T00:00:00Z'}});await tick();assert.equal(f.document.getElementById('account-paid-membership-open').hidden,false);assert.equal(f.calls.filter(c=>c.options?.body?.action==='sync').length,0);
});

Deno.test('a fresh stop-sales result removes new purchase controls without stranding existing members',async()=>{
 for(const existing of [false,true]){
  const f=fixture({ready:true,open:true,member:{sandbox:false,status:existing?'active':'none',has_customer:existing,has_access:existing,access_until:'2027-01-01T00:00:00Z'}});await tick();
  f.setInvoke(async options=>({data:options.method==='GET'?{sandbox:false,service_ready:true,checkout_open:false}:{sandbox:false,updated:true}}));f.refresh();await tick();
  assert.equal(f.document.getElementById('supporter-live-membership').hidden,!existing);assert([...f.document.querySelectorAll('[data-live-action="checkout"]')].every(button=>button.hidden));assert.match(f.document.getElementById('supporter-payment-state').textContent,/payments are not open/);if(existing)assert.equal(f.document.querySelector('[data-live-action="portal"]').hidden,false);
 }
});
