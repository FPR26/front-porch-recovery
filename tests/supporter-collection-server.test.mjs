import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';import vm from 'node:vm';
import {makeSupporterCardHandler} from '../supabase/functions/_shared/supporter-card-handler.mjs';
import {CARD_DESIGNS,CARD_BRAND_LOGO,renderSupporterCardSvg} from '../supabase/functions/_shared/supporter-card-art.mjs';
const req=(body={design:'light'},token='Bearer member',origin='https://fpr26.github.io')=>new Request('https://example.test',{method:'POST',headers:{authorization:token,origin},body:typeof body==='string'?body:JSON.stringify(body)});
test('unsigned and inactive callers cannot render clean collection art',async()=>{
 let renders=0;const handler=makeSupporterCardHandler({verifyAccess:async header=>header==='Bearer member'?{can_write:false}:null,render:()=>{renders++;return 'art'}});
 assert.equal((await handler(req({},''))).status,401);assert.equal((await handler(req())).status,403);assert.equal(renders,0);
});
test('every download rechecks access; revoked access denies subsequent request',async()=>{
 let active=true,checks=0;const handler=makeSupporterCardHandler({verifyAccess:async()=>{checks++;return {can_write:active}}});
 const response=await handler(req({design:'steps',user_id:'other',can_write:true}));assert.equal(response.status,200);const body=await response.json();assert.equal(body.filename,'fpr-steps-collection.png');assert(body.svg.startsWith('<svg'));assert(!body.svg.includes('other'));assert.equal(response.headers.get('cache-control'),'no-store');
 active=false;assert.equal((await handler(req())).status,403);assert.equal(checks,2);
});
test('malformed, oversized, unknown design and foreign-origin requests fail closed',async()=>{
 const handler=makeSupporterCardHandler({verifyAccess:async()=>({can_write:true})});
 for(const body of ['{','null',{}, {design:'<script>'}])assert.equal((await handler(req(body))).status,400);
 assert.equal((await handler(req('a'.repeat(513)))).status,413);assert.equal((await handler(req({},'Bearer member','https://other.invalid'))).status,403);
 assert.equal((await handler(new Request('https://example.test'))).status,405);
 const broken=makeSupporterCardHandler({verifyAccess:async()=>{throw Error('private credential')}});const failed=await broken(req());assert.equal(failed.status,503);assert(!(await failed.text()).includes('credential'));
});
test('six release designs match public catalog; SVG includes only fixed artwork',()=>{
 const html=fs.readFileSync(new URL('../index.html',import.meta.url),'utf8'),start=html.indexOf('const SUPPORTER_WORKBOOK ='),end=html.indexOf('(function initSupporterPreview(){',start);
 const browserDesigns=vm.runInNewContext(html.slice(start,end)+';SUPPORTER_CARD_DESIGNS');assert.equal(JSON.stringify(CARD_DESIGNS),JSON.stringify(browserDesigns));
 for(const d of CARD_DESIGNS){const svg=renderSupporterCardSvg(d.id);assert(svg.includes('width="1200" height="1200"'));assert(CARD_BRAND_LOGO.startsWith('data:image/png;base64,'));assert(!svg.includes('<image'));assert(svg.includes('FRONT PORCH RECOVERY'));assert(!svg.includes('DESIGN PREVIEW'));assert(!svg.includes('<script'));assert(!svg.includes('http://') || svg.includes('xmlns="http://www.w3.org/2000/svg"'));}
 assert.throws(()=>renderSupporterCardSvg('unknown'),/Unknown/);
});
