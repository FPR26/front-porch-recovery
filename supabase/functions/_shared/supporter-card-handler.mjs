import {CARD_DESIGNS,CARD_BRAND_LOGO,renderSupporterCardSvg} from './supporter-card-art.mjs';
export function makeSupporterCardHandler({verifyAccess,render=renderSupporterCardSvg}){
 const origin='https://fpr26.github.io';
 const headers={'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin','Access-Control-Allow-Origin':origin};
 const json=(body,status=200)=>new Response(JSON.stringify(body),{status,headers});
 return async req=>{
  if(req.headers.get('origin') && req.headers.get('origin')!==origin)return json({error:'Origin not allowed.'},403);
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers:{...headers,'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS'}});
  if(req.method!=='POST')return json({error:'Use POST.'},405);
  try{
   const access=await verifyAccess(req.headers.get('authorization') || '');
   if(!access)return json({error:'Sign in required.'},401);
   if(access.can_write!==true)return json({error:'Collection access is not active. Free samples remain available.'},403);
   if(Number(req.headers.get('content-length') || 0)>512)return json({error:'Request too large.'},413);
   const text=await req.text();if(text.length>512)return json({error:'Request too large.'},413);
   let body;try{body=JSON.parse(text)}catch{return json({error:'Choose a card design.'},400)}
   if(!body || typeof body!=='object' || !CARD_DESIGNS.some(d=>d.id===body.design))return json({error:'Choose a card design.'},400);
   return json({svg:render(body.design),logo:CARD_BRAND_LOGO,filename:'fpr-'+body.design+'-collection.png'});
  }catch{return json({error:'Could not load the collection. Please try again.'},503)}
 };
}
