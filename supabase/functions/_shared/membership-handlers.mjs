// Dependency-injected handlers: no keys, payment details, or recovery data.
export function makeMembershipHandlers({stripe,store,verifyUser,verifyEvent,config,uuid=()=>crypto.randomUUID(),now=()=>Date.now(),sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms)),report=entry=>console.error(JSON.stringify(entry)),checkoutAllowed=async()=>true}) {
  const liveMode=config.liveMode===true,sandbox=!liveMode,keyPrefix=liveMode?'fpr-live':'fpr-sandbox';
  const origin='https://fpr26.github.io';
  const home='https://fpr26.github.io/front-porch-recovery/';
  function json(data,status=200,cors=false){return new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store',...(cors?{'Access-Control-Allow-Origin':origin,'Vary':'Origin'}:{})}})}
  // Log fixed labels only; never raw errors, IDs, payloads or credentials.
  async function stage(name,action){
    try{return await action()}catch(cause){throw {membershipStage:name,cause}}
  }
  function diagnostic(error){
    const cause=error?.cause || error;
    const category=cause?.membershipBusy?'busy':
      ['StripeConnectionError','StripeAPIError','StripeAuthenticationError','StripePermissionError','StripeRateLimitError','StripeInvalidRequestError'].includes(cause?.type)?cause.type:'operation_failed';
    const entry={component:'membership',stage:error?.membershipStage || 'request',category};
    if(Number.isInteger(cause?.statusCode) && cause.statusCode>=400 && cause.statusCode<=599)entry.http_status=cause.statusCode;
    try{report(entry)}catch{/* Logging must not change billing behavior. */}
  }
  async function locked(userId,action,retry=false){
    const token=uuid();
    let claimed=await stage('lock_claim',()=>store.claim(userId,token));
    // Briefly retry denied claims for signed webhook bursts, not operation errors.
    if(retry)for(const delay of [150,350,750]){
      if(claimed)break;
      await sleep(delay);
      claimed=await stage('lock_claim',()=>store.claim(userId,token));
    }
    if(!claimed)throw {membershipStage:'lock_claim',cause:{membershipBusy:true},status:409,message:'A membership update is in progress. Please try again shortly.'};
    let failed=false;
    try{return await action(token)}catch(error){failed=true;throw error}
    finally{
      try{await stage('lock_release',()=>store.release(userId,token))}
      catch(error){if(failed)diagnostic(error);else throw error}
    }
  }
  async function subscriptions(customer){
    const page=await stage('stripe_subscriptions',()=>stripe.subscriptions.list({customer,status:'all',limit:100,expand:['data.latest_invoice']}));
    if(page.has_more) throw Error('Subscription review required');
    if(liveMode && page.data.some(sub=>sub.livemode!==true || (typeof sub.customer==='string'?sub.customer:sub.customer?.id)!==customer))throw Error('Billing identity or mode mismatch');
    if(liveMode)for(const sub of page.data){
      const invoice=sub.latest_invoice;
      if(sub.status==='active' && invoice?.lines?.has_more===true){
        const lines=await stage('stripe_invoice_lines',()=>stripe.invoices.listLineItems(invoice.id,{limit:100}));
        if(lines.has_more)throw Error('Invoice review required');
        invoice.lines=lines;
      }
    }
    return page.data;
  }
  function cancellationTime(sub){
    return Number.isFinite(sub.cancel_at) && sub.cancel_at>0 ? sub.cancel_at : null;
  }
  function paidCoverageEnd(sub){
    const item=sub.items?.data?.[0],invoice=sub.latest_invoice;
    if(!item?.id || invoice?.livemode!==true || invoice.currency!=='usd' || invoice.lines?.has_more!==false)return NaN;
    const invoiceSubscription=invoice.parent?.subscription_details?.subscription ?? invoice.subscription;
    if((typeof invoiceSubscription==='string'?invoiceSubscription:invoiceSubscription?.id)!==sub.id)return NaN;
    const lines=invoice.lines?.data || [];
    const ends=lines.filter(line=>{
      const detail=line.parent?.subscription_item_details;
      const itemId=detail?.subscription_item ?? line.subscription_item;
      const priceValue=line.pricing?.price_details?.price ?? line.price;
      const linePrice=typeof priceValue==='string'?priceValue:priceValue?.id;
      return itemId===item.id && linePrice===item.price.id && line.amount>0 && Number.isFinite(line.period?.start) && Number.isFinite(line.period?.end) && line.period.start*1000<=now() && line.period.end*1000>now();
    }).map(line=>line.period.end);
    return ends.length?Math.max(...ends):NaN;
  }
  function accessEnd(sub){
    const periodEnd=sub.items?.data?.[0]?.current_period_end;
    return Math.min(periodEnd,cancellationTime(sub) ?? Infinity,liveMode?paidCoverageEnd(sub):Infinity);
  }
  function approvedLivePrice(price){
    const plan=Object.keys(config.prices).find(name=>config.prices[name]===price?.id);
    const product=typeof price?.product==='string'?price.product:price?.product?.id;
    return !!plan && price.livemode===true && product===config.product && price.currency==='usd' && price.unit_amount===(plan==='monthly'?300:2500) && price.recurring?.interval===(plan==='monthly'?'month':'year') && price.recurring.interval_count===1 && price.recurring.usage_type==='licensed';
  }
  function eligible(sub){
    return sub.livemode===liveMode && sub.status==='active' && sub.latest_invoice?.status==='paid' &&
      sub.items?.data?.length===1 && (!liveMode || (sub.items.data[0].quantity===1 && approvedLivePrice(sub.items.data[0].price))) && Object.values(config.prices).includes(sub.items.data[0].price.id) &&
      Number.isFinite(sub.items.data[0].current_period_end) && accessEnd(sub)*1000>now();
  }
  async function synchronize(row,token){
    const all=await subscriptions(row.customer_id);
    const paid=all.filter(eligible).sort((a,b)=>accessEnd(b)-accessEnd(a))[0];
    const latest=paid || all.slice().sort((a,b)=>b.created-a.created)[0];
    await stage('snapshot_save',()=>store.snapshot(row.user_id,token,{
      subscription_id:latest?.id || null,status:paid?'active':(latest?.status==='active'?'payment_pending':latest?.status || 'none'),
      access_until:paid?new Date(accessEnd(paid)*1000).toISOString():null,
      // Normalize classic's boolean and flexible billing's cancel_at date
      // into the existing scheduled-cancellation field used by the UI.
      cancel_at_period_end:!!paid && (paid.cancel_at_period_end===true || cancellationTime(paid)!==null)
    }));
    return all;
  }
  async function api(req){
    const cors=req.headers.get('origin')===origin;
    if(req.headers.get('origin') && !cors)return json({error:'Origin not allowed.'},403);
    if(req.method==='OPTIONS')return new Response(null,{status:204,headers:{'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':liveMode?'GET, POST, OPTIONS':'POST, OPTIONS','Vary':'Origin'}});
    if(liveMode && req.method==='GET'){
      try{return json({sandbox:false,service_ready:config.enabled===true,checkout_open:config.enabled===true && await checkoutAllowed()},200,cors)}
      catch{return json({sandbox:false,service_ready:false,checkout_open:false},200,cors)}
    }
    if(req.method!=='POST')return json({error:'Use POST.'},405,cors);
    if(!config.enabled)return json({error:liveMode?'Membership service is not open.':'Membership testing is not enabled yet.'},503,cors);
    try{
      const user=await verifyUser(req.headers.get('authorization') || '');
      if(!user) return json({error:'Sign in required.'},401,cors);
      if(Number(req.headers.get('content-length') || 0)>2048)return json({error:'Request too large.'},413,cors);
      const text=await req.text();if(text.length>2048)return json({error:'Request too large.'},413,cors);
      let body;try{body=JSON.parse(text)}catch{return json({error:'Invalid request.'},400,cors)}
      if(!body || typeof body!=='object')return json({error:'Invalid request.'},400,cors);
      if(!['checkout','portal','sync'].includes(body.action))return json({error:'Unknown membership action.'},400,cors);
      if(body.action==='checkout' && !['monthly','yearly'].includes(body.plan))return json({error:'Choose monthly or yearly.'},400,cors);
      if(body.action==='checkout' && liveMode && !await checkoutAllowed())return json({error:'New memberships are not open.'},409,cors);
      return await locked(user.id,async token=>{
        let row=await store.get(user.id);
        if(body.action==='sync'){
          if(row.customer_id)await synchronize(row,token);
          return json({sandbox,updated:true},200,cors);
        }
        if(body.action==='portal'){
          if(!row.customer_id)return json({error:'No membership billing account exists yet.'},409,cors);
          const portal=await stripe.billingPortal.sessions.create({customer:row.customer_id,configuration:config.portalConfiguration,return_url:home+'#supporter'});
          return json({sandbox,url:portal.url},200,cors);
        }
        const priceId=config.prices[body.plan];
        const price=await stripe.prices.retrieve(priceId);
        if((liveMode && !approvedLivePrice(price)) || price.livemode!==liveMode || !price.active || price.currency!=='usd' || price.unit_amount!==(body.plan==='monthly'?300:2500) || price.recurring?.interval!==(body.plan==='monthly'?'month':'year') || price.recurring.interval_count!==1 || price.product!==config.product)throw Error('Price configuration mismatch');
        if(!row.customer_id){
          const customer=await stripe.customers.create({metadata:{fpr_user_id:user.id}},{idempotencyKey:keyPrefix+'-customer-'+user.id});
          if(liveMode && customer.livemode!==true)throw Error('Customer mode mismatch');
          await store.setCustomer(user.id,token,customer.id);row=await store.get(user.id);
        }
        const all=await synchronize(row,token);
        if(all.some(s=>!['canceled','incomplete_expired'].includes(s.status)))return json({error:'A subscription already exists. Use Manage membership instead.'},409,cors);
        const open=await stripe.checkout.sessions.list({customer:row.customer_id,status:'open',limit:100});
        if(open.has_more)throw Error('Checkout review required');
        if(liveMode && open.data.some(session=>session.livemode!==true))throw Error('Checkout mode mismatch');
        if(liveMode && !await checkoutAllowed())return json({error:'New memberships are not open.'},409,cors);
        const matching=open.data.find(s=>s.mode==='subscription' && s.metadata?.fpr_app==='front-porch-recovery' && s.metadata?.fpr_plan===body.plan);
        if(matching)return json({sandbox,url:matching.url},200,cors);
        for(const s of open.data)if(s.mode==='subscription' && s.metadata?.fpr_app==='front-porch-recovery')await stripe.checkout.sessions.expire(s.id);
        await store.renew(user.id,token);
        if(liveMode && !await checkoutAllowed())return json({error:'New memberships are not open.'},409,cors);
        const session=await stripe.checkout.sessions.create({mode:'subscription',ui_mode:'hosted',customer:row.customer_id,
          line_items:[{price:priceId,quantity:1}],success_url:home+'?membership=returned#supporter',cancel_url:home+'?membership=canceled#supporter',
          metadata:{fpr_app:'front-porch-recovery',fpr_plan:body.plan,fpr_mode:liveMode?'live':'sandbox'},subscription_data:{metadata:{fpr_app:'front-porch-recovery',fpr_mode:liveMode?'live':'sandbox'}},
          allow_promotion_codes:false,payment_method_collection:'always'},{idempotencyKey:keyPrefix+'-checkout-'+token});
        if(liveMode && session.livemode!==true)throw Error('Checkout mode mismatch');
        return json({sandbox,url:session.url},200,cors);
      });
    }catch(err){diagnostic(err);return json({error:err?.status===409?err.message:'Membership service is temporarily unavailable.'},err?.status===409?409:503,cors)}
  }
  async function webhook(req){
    if(req.method!=='POST')return json({error:'Use POST.'},405);
    if(!config.enabled)return json({error:liveMode?'Membership service is not open.':'Membership testing is not enabled.'},503);
    let event;
    try{event=await verifyEvent(await req.text(),req.headers.get('stripe-signature') || '')}catch{return json({error:'Invalid Stripe signature.'},400)}
    if(event.livemode!==liveMode)return json({error:liveMode?'This endpoint accepts live events only.':'This endpoint accepts sandbox events only.'},400);
    if(!['checkout.session.completed','checkout.session.async_payment_succeeded','checkout.session.async_payment_failed','customer.subscription.created','customer.subscription.updated','customer.subscription.deleted','customer.subscription.paused','customer.subscription.resumed','invoice.paid','invoice.payment_failed','invoice.payment_action_required','invoice.voided','invoice.marked_uncollectible'].includes(event.type))return json({received:true});
    const customer=event.data?.object?.customer;
    if(typeof customer!=='string')return json({received:true});
    try{
      const row=await stage('customer_lookup',()=>store.byCustomer(customer));
      if(!row)return json({received:true});
      await locked(row.user_id,token=>synchronize(row,token),true);
      // Always re-read Stripe under the same lock used by checkout. Replayed
      // or out-of-order events cannot overwrite state using stale payloads.
      return json({received:true});
    }catch(error){diagnostic(error);return json({error:'Retry this billing update.'},503)}
  }
  return {api,webhook};
}
