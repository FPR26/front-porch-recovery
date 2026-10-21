import {test} from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import vm from 'node:vm';
const html=fs.readFileSync(new URL('../index.html',import.meta.url),'utf8');const start=html.indexOf('(function initMembershipSandbox(){');const code=html.slice(start,html.indexOf('})();',start)+5);
const tick=()=>new Promise(r=>setTimeout(r,5));
function fixture(isAdmin=true,membership={sandbox:true,has_access:false,status:'none'}){
 const buttons=['checkout','portal','sync'].map(action=>({dataset:{memberAction:action,memberPlan:'monthly'},events:{},addEventListener(n,f){this.events[n]=f}}));const panel={hidden:false,querySelectorAll:()=>buttons},status={textContent:''};let signedIn=true,onAuth,invoke=async()=>({data:{sandbox:true,url:'https://checkout.stripe.com/test'}});const redirects=[];
 const client={auth:{getSession:async()=>({data:{session:signedIn?{}:null}}),onAuthStateChange:f=>onAuth=f},rpc:async name=>name==='is_admin'?{data:isAdmin}:{data:[membership]},functions:{invoke:(...args)=>invoke(...args)}};
 vm.runInNewContext(code,{document:{getElementById:id=>id==='supporter-sandbox'?panel:status,addEventListener(){}},window:{__fprSupabaseClient:client,location:{assign:url=>redirects.push(url)}},setTimeout,URL});
 return {buttons,panel,status,redirects,setInvoke:f=>invoke=f,signout(){signedIn=false;onAuth()}};
}
test('nonadmins never see sandbox controls',async()=>{const f=fixture(false);await tick();assert.equal(f.panel.hidden,true)});
test('verified admin gets controls; only official HTTPS destinations redirect',async()=>{const f=fixture();await tick();assert.equal(f.panel.hidden,false);f.setInvoke(async()=>({data:{sandbox:true,url:'https://evil.test/'}}));await f.buttons[0].events.click();assert.equal(f.redirects.length,0);f.setInvoke(async()=>({data:{sandbox:true,url:'https://checkout.stripe.com/test'}}));await f.buttons[0].events.click();assert.equal(f.redirects.length,1)});
test('signout suppresses an in-flight checkout redirect',async()=>{const f=fixture();await tick();let done;f.setInvoke(()=>new Promise(r=>done=r));const pending=f.buttons[0].events.click();f.signout();done({data:{sandbox:true,url:'https://checkout.stripe.com/test'}});await pending;await tick();assert.equal(f.panel.hidden,true);assert.equal(f.redirects.length,0)});
test('status refresh labels test state and does not grant live access',async()=>{const f=fixture();await tick();f.setInvoke(async()=>({data:{sandbox:true,updated:true}}));await f.buttons[2].events.click();assert.match(f.status.textContent,/No real paid membership/)});

test('verified scheduled cancellation displays its confirmation',async()=>{const f=fixture(true,{sandbox:true,has_access:true,status:'active',access_until:'2026-11-21T18:45:27Z',cancel_at_period_end:true});await tick();f.setInvoke(async()=>({data:{sandbox:true,updated:true}}));await f.buttons[2].events.click();assert.match(f.status.textContent,/cancellation is scheduled/);});
