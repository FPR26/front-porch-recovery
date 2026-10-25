// Only exact explicit enablement plus complete live configuration can start processing.
export function readLiveMembershipConfig(env){
 const key=env('STRIPE_LIVE_SECRET_KEY'),webhookSecret=env('STRIPE_LIVE_WEBHOOK_SECRET');
 const product=env('STRIPE_LIVE_PRODUCT_ID'),monthly=env('STRIPE_LIVE_MONTHLY_PRICE_ID'),yearly=env('STRIPE_LIVE_YEARLY_PRICE_ID'),portalConfiguration=env('STRIPE_LIVE_PORTAL_CONFIGURATION_ID');
 const ready=env('FPR_MEMBERSHIP_LIVE_ENABLED')==='true' && /^(sk|rk)_live_[A-Za-z0-9]+$/.test(key) && /^whsec_[A-Za-z0-9]+$/.test(webhookSecret) && /^prod_[A-Za-z0-9]+$/.test(product) && /^price_[A-Za-z0-9]+$/.test(monthly) && /^price_[A-Za-z0-9]+$/.test(yearly) && monthly!==yearly && /^bpc_[A-Za-z0-9]+$/.test(portalConfiguration);
 return {ready,key,webhookSecret,product,prices:{monthly,yearly},portalConfiguration};
}
