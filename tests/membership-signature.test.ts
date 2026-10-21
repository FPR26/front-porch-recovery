import Stripe from 'npm:stripe@19.1.0';
const stripe=new Stripe('sk_test_dummy_not_a_real_key');
const secret='whsec_local_fixture_only';
Deno.test('Stripe SDK verifies the raw signature, rejects tampering, and rejects expired signatures',async()=>{
  const payload=JSON.stringify({id:'evt_fixture',type:'customer.subscription.updated',livemode:false,data:{object:{customer:'cus_fixture'}}});
  const signature=await stripe.webhooks.generateTestHeaderStringAsync({payload,secret});
  const result=await stripe.webhooks.constructEventAsync(payload,signature,secret,undefined,Stripe.createSubtleCryptoProvider());
  if(result.id!=='evt_fixture')throw Error('Wrong event');
  for(const [body,sig] of [[payload+' ',signature],[payload,await stripe.webhooks.generateTestHeaderStringAsync({payload,secret,timestamp:1})]]){
    let rejected=false;try{await stripe.webhooks.constructEventAsync(body,sig,secret,undefined,Stripe.createSubtleCryptoProvider())}catch{rejected=true}
    if(!rejected)throw Error('Invalid signature accepted');
  }
});
