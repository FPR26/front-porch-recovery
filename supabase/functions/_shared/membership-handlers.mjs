// Dependency-injected handlers: no keys, payment details, or recovery data.
export function makeMembershipHandlers({stripe,store,verifyUser,verifyEvent,config,uuid=()=>crypto.randomUUID(),now=()=>Date.now()}) {
  const origin='https://fpr26.github.io';
  const home='https://fpr26.github.io/front-porch-recovery/';
  function json(data,status=200,cors=false){return new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store',...(cors?{'Access-Control-Allow-Origin':origin,'Vary':'Origin'}:{})}})}
  async function locked(userId,action){
    const token=uuid();
    if(!await store.claim(userId,token)) throw {status:409,message:'A membership update is in progress. Please try again shortly.'};
    try{return await action(token)}finally{await store.release(userId,token)}
  }
  async function subscriptions(customer){
    const page=await stripe.subscriptions.list({customer,status:'all',limit:100,expand:['data.latest_invoice']});
    if(page.has_more) throw Error('Subscription review required');
    return page.data;
  }
  function eligible(sub){
    return sub.livemode===false && sub.status==='active' && sub.latest_invoice?.status==='paid' &&
      sub.items?.data?.length===1 && Object.values(config.prices).includes(sub.items.data[0].price.id) &&
      Number.isFinite(sub.items.data[0].current_period_end) && sub.items.data[0].current_period_end*1000>now();
  }
  async function synchronize(row,token){
    const all=await subscriptions(row.customer_id);
    const paid=all.filter(eligible).sort((a,b)=>b.items.data[0].current_period_end-a.items.data[0].current_period_end)[0];
    const latest=paid || all.slice().sort((a,b)=>b.created-a.created)[0];
    await store.snapshot(row.user_id,token,{
      subscription_id:latest?.id || null,status:paid?'active':(latest?.status==='active'?'payment_pending':latest?.status || 'none'),
      access_until:paid?new Date(paid.items.data[0].current_period_end*1000).toISOString():null,
      cancel_at_period_end:paid?.cancel_at_period_end || false
    });
    return all;
  }
  async function api(req){
    const cors=req.headers.get('origin')===origin;
    if(req.headers.get('origin') && !cors)return json({error:'Origin not allowed.'},403);
    if(req.method==='OPTIONS')return new Response(null,{status:204,headers:{'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin'}});
    if(req.method!=='POST')return json({error:'Use POST.'},405,cors);
    if(!config.enabled)return json({error:'Membership testing is not enabled yet.'},503,cors);
    try{
      const user=await verifyUser(req.headers.get('authorization') || '');
      if(!user) return json({error:'Sign in required.'},401,cors);
      if(Number(req.headers.get('content-length') || 0)>2048)return json({error:'Request too large.'},413,cors);
      const text=await req.text();if(text.length>2048)return json({error:'Request too large.'},413,cors);
      let body;try{body=JSON.parse(text)}catch{return json({error:'Invalid request.'},400,cors)}
      if(!body || typeof body!=='object')return json({error:'Invalid request.'},400,cors);
      if(!['checkout','portal','sync'].includes(body.action))return json({error:'Unknown membership action.'},400,cors);
      if(body.action==='checkout' && !['monthly','yearly'].includes(body.plan))return json({error:'Choose monthly or yearly.'},400,cors);
      return await locked(user.id,async token=>{
        let row=await store.get(user.id);
        if(body.action==='sync'){
          if(row.customer_id)await synchronize(row,token);
          return json({sandbox:true,updated:true},200,cors);
        }
        if(body.action==='portal'){
          if(!row.customer_id)return json({error:'No membership billing account exists yet.'},409,cors);
          const portal=await stripe.billingPortal.sessions.create({customer:row.customer_id,configuration:config.portalConfiguration,return_url:home+'#supporter'});
          return json({sandbox:true,url:portal.url},200,cors);
        }
        const priceId=config.prices[body.plan];
        const price=await stripe.prices.retrieve(priceId);
        if(price.livemode!==false || !price.active || price.currency!=='usd' || price.unit_amount!==(body.plan==='monthly'?300:2500) || price.recurring?.interval!==(body.plan==='monthly'?'month':'year') || price.recurring.interval_count!==1 || price.product!==config.product)throw Error('Price configuration mismatch');
        if(!row.customer_id){
          const customer=await stripe.customers.create({metadata:{fpr_user_id:user.id}},{idempotencyKey:'fpr-sandbox-customer-'+user.id});
          await store.setCustomer(user.id,token,customer.id);row=await store.get(user.id);
        }
        const all=await synchronize(row,token);
        if(all.some(s=>!['canceled','incomplete_expired'].includes(s.status)))return json({error:'A subscription already exists. Use Manage membership instead.'},409,cors);
        const open=await stripe.checkout.sessions.list({customer:row.customer_id,status:'open',limit:100});
        if(open.has_more)throw Error('Checkout review required');
        const matching=open.data.find(s=>s.mode==='subscription' && s.metadata?.fpr_app==='front-porch-recovery' && s.metadata?.fpr_plan===body.plan);
        if(matching)return json({sandbox:true,url:matching.url},200,cors);
        for(const s of open.data)if(s.mode==='subscription' && s.metadata?.fpr_app==='front-porch-recovery')await stripe.checkout.sessions.expire(s.id);
        await store.renew(user.id,token);
        const session=await stripe.checkout.sessions.create({mode:'subscription',ui_mode:'hosted',customer:row.customer_id,
          line_items:[{price:priceId,quantity:1}],success_url:home+'?membership=returned#supporter',cancel_url:home+'?membership=canceled#supporter',
          metadata:{fpr_app:'front-porch-recovery',fpr_plan:body.plan},subscription_data:{metadata:{fpr_app:'front-porch-recovery'}},
          allow_promotion_codes:false,payment_method_collection:'always'},{idempotencyKey:'fpr-sandbox-checkout-'+token});
        return json({sandbox:true,url:session.url},200,cors);
      });
    }catch(err){return json({error:err?.status===409?err.message:'Membership service is temporarily unavailable.'},err?.status===409?409:503,cors)}
  }
  async function webhook(req){
    if(req.method!=='POST')return json({error:'Use POST.'},405);
    if(!config.enabled)return json({error:'Membership testing is not enabled.'},503);
    let event;
    try{event=await verifyEvent(await req.text(),req.headers.get('stripe-signature') || '')}catch{return json({error:'Invalid Stripe signature.'},400)}
    if(event.livemode!==false)return json({error:'This endpoint accepts sandbox events only.'},400);
    if(!['checkout.session.completed','checkout.session.async_payment_succeeded','checkout.session.async_payment_failed','customer.subscription.created','customer.subscription.updated','customer.subscription.deleted','invoice.paid','invoice.payment_failed'].includes(event.type))return json({received:true});
    const customer=event.data?.object?.customer;
    if(typeof customer!=='string')return json({received:true});
    try{
      const row=await store.byCustomer(customer);
      if(!row)return json({received:true});
      await locked(row.user_id,token=>synchronize(row,token));
      // Always re-read Stripe under the same lock used by checkout. Replayed
      // or out-of-order events cannot overwrite state using stale payloads.
      return json({received:true});
    }catch{return json({error:'Retry this billing update.'},503)}
  }
  return {api,webhook};
}
