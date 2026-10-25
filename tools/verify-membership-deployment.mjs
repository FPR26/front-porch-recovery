// Read-only checks for the current, deliberately CLOSED production deployment.
// No secret keys, sign-in, Stripe requests, purchases, or database mutations.
const site='https://fpr26.github.io/front-porch-recovery/';
const backend='https://ptmazxslypzslhhcqudn.supabase.co';
const publicKey='sb_publishable_1_TI_W8Zuk9319d-akZYrw_uAEVBtz8';
const checks=[];
async function check(name,run){try{await run();checks.push({name,passed:true})}catch(error){checks.push({name,passed:false,reason:error.message})}}
function expect(value,message){if(!value)throw Error(message)}
async function request(url,options={}){return await fetch(url,{...options,signal:AbortSignal.timeout(15000),headers:{'Cache-Control':'no-cache',...options.headers}})}
await check('Published membership interface',async()=>{
 const response=await request(site+'?membership-deployment-check='+Date.now());
 expect(response.ok,'Website HTTP '+response.status);const html=await response.text();
 for(const id of ['supporter-live-membership','account-paid-membership-open','supporter-workbook-title','supporter-benefits'])expect(html.includes('id="'+id+'"'),'Missing interface: '+id);
});
await check('Production checkout remains closed',async()=>{
 const response=await request(backend+'/functions/v1/membership-live-api');
 expect(response.status===200,'Availability HTTP '+response.status);const state=await response.json();
 expect(state.sandbox===false && state.service_ready===false && state.checkout_open===false,'Expected production processing AND checkout disabled; do not use this closed-phase check after approved configuration');
});
await check('Disabled webhook refuses processing',async()=>{
 const response=await request(backend+'/functions/v1/stripe-live-webhook',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});
 const data=await response.json();expect(response.status===503 && data.error==='Membership service is not open.','Webhook does not match the disabled deployment');
});
for(const rpc of ['get_my_paid_membership','get_my_supporter_benefits'])await check('Database function exists and denies anonymous access: '+rpc,async()=>{
 const response=await request(backend+'/rest/v1/rpc/'+rpc,{method:'POST',headers:{apikey:publicKey,'Content-Type':'application/json'},body:'{}'});
 const result=await response.json();expect(response.status===401 && result.code==='42501','Expected permission denial for an installed function; HTTP '+response.status+' / '+(result.code||'unknown'));
});
const result={checked_at:new Date().toISOString(),scope:'Closed deployment only; no live-account, authenticated-member, private launch-flag, or payment acceptance claim',passed:checks.every(c=>c.passed),checks};
console.log(JSON.stringify(result,null,2));
if(!result.passed)process.exitCode=1;
