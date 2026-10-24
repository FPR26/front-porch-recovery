import {parseHTML} from 'npm:linkedom@0.18.12';
import fs from 'node:fs';import vm from 'node:vm';import assert from 'node:assert/strict';
const html=fs.readFileSync(new URL('../index.html',import.meta.url),'utf8');
const data=html.slice(html.indexOf('const SUPPORTER_WORKBOOK ='),html.indexOf('function drawSupporterSample'));
const start=html.indexOf('(function initPrivateSupporterWorkbook(){');const code=html.slice(start,html.indexOf('})();',start)+5);
const tick=()=>new Promise(r=>setTimeout(r,10));
function fixture({allowed=true,entries=[],user='A'}={}){
 const {window}=parseHTML(html);const {document}=window;document.querySelectorAll('.page').forEach(p=>p.classList.remove('active'));document.getElementById('page-supporter').classList.add('active');
 let onAuth,identity=user,canWrite=allowed,records=entries,saveFailure=null,getOverride=null;const calls=[];
 const client={auth:{getSession:async()=>({data:{session:identity?{user:{id:identity}}:null}}),onAuthStateChange:f=>onAuth=f},rpc:async(name,args)=>{calls.push({name,args});
 if(name==='get_my_supporter_workbook')return getOverride?await getOverride():{data:{can_write:canWrite,access_until:null,entries:structuredClone(records)}};
 if(name==='save_my_supporter_reflection'){if(saveFailure)return {error:{code:saveFailure}};records=[{reflection_number:args.p_reflection,answers:args.p_answers,completed:args.p_completed,version:2}];return {data:2};}
 if(name==='clear_my_supporter_reflection'){records=[];return {data:null};}
 throw Error('Unexpected RPC '+name)}};
 window.__fprSupabaseClient=client;window.confirm=()=>true;new Function('window','document','CustomEvent','setTimeout',data+code)(window,document,window.CustomEvent,setTimeout);
 return {window,document,calls,async changeUser(id,newEntries=[]){identity=id;records=newEntries;onAuth('SIGNED_OUT',id?{user:{id}}:null);await tick();},setFailure:value=>saveFailure=value,setGetter:f=>getOverride=f,setAllowed:v=>canWrite=v};
}
Deno.test('workbook saves only explicitly, validates completion, and preserves a failed draft',async()=>{
 const f=fixture();await tick();const d=f.document,form=d.getElementById('supporter-workbook-form');assert.equal(form.hidden,false);
 const inputs=[...d.querySelectorAll('#supporter-answer-fields textarea')];inputs.forEach((t,i)=>{t.value='answer '+i;t.dispatchEvent(new f.window.Event('input'));});assert.equal(f.calls.filter(c=>c.name.startsWith('save')).length,0);
 form.dispatchEvent(new f.window.Event('submit',{cancelable:true}));await tick();assert.equal(f.calls.find(c=>c.name==='save_my_supporter_reflection').args.p_version,0);assert.match(d.getElementById('supporter-workbook-status').textContent,/saved privately/);
 const first=d.querySelector('#supporter-answer-fields textarea');first.value='unsaved private draft';first.dispatchEvent(new f.window.Event('input'));f.setFailure('40001');form.dispatchEvent(new f.window.Event('submit',{cancelable:true}));await tick();assert.equal(first.value,'unsaved private draft');assert.match(d.getElementById('supporter-workbook-status').textContent,/another tab/);
});
Deno.test('switching reflections respects unsaved-change confirmation',async()=>{
 const f=fixture();await tick();const first=f.document.querySelector('#supporter-answer-fields textarea');first.value='keep draft';first.dispatchEvent(new f.window.Event('input'));f.window.confirm=()=>false;
 const event=new f.window.CustomEvent('fpr:workbookselect',{detail:{index:1},cancelable:true});f.document.dispatchEvent(event);assert.equal(event.defaultPrevented,true);assert.equal(first.value,'keep draft');
});
Deno.test('revoked access is read-only; owner can still clear saved answers',async()=>{
 const f=fixture({allowed:false,entries:[{reflection_number:1,answers:['private','',''],completed:false,version:3}]});await tick();const d=f.document;assert.equal(d.getElementById('supporter-workbook-form').hidden,false);assert.equal(d.querySelector('#supporter-answer-fields textarea').readOnly,true);assert.equal(d.getElementById('supporter-workbook-save').disabled,true);
 d.getElementById('supporter-workbook-clear').click();await tick();assert(f.calls.some(c=>c.name==='clear_my_supporter_reflection'));assert.equal(d.getElementById('supporter-workbook-form').hidden,true);
});
Deno.test('signout and account switching clear private answers immediately',async()=>{
 const f=fixture({entries:[{reflection_number:1,answers:['OWNER A SECRET','',''],completed:false,version:1}]});await tick();assert.equal(f.document.querySelector('#supporter-answer-fields textarea').value,'OWNER A SECRET');await f.changeUser(null);assert.equal(f.document.getElementById('supporter-workbook-form').hidden,true);assert(!f.document.getElementById('supporter-answer-fields').textContent.includes('OWNER A SECRET'));await f.changeUser('B');assert.equal(f.document.querySelector('#supporter-answer-fields textarea').value,'');
});
Deno.test('late responses from the previous identity cannot restore old answers',async()=>{
 const f=fixture();await tick();let resolve;f.setGetter(()=>new Promise(r=>resolve=r));f.document.getElementById('supporter-workbook-reload').click();await tick();await f.changeUser(null);resolve({data:{can_write:true,entries:[{reflection_number:1,answers:['OLD SECRET','',''],version:1}]}});await tick();assert.equal(f.document.getElementById('supporter-workbook-form').hidden,true);assert(!f.document.getElementById('supporter-answer-fields').textContent.includes('OLD SECRET'));
});
Deno.test('signed-out workbook never requests private records',async()=>{const f=fixture({user:null});await tick();assert.equal(f.calls.length,0);assert.equal(f.document.getElementById('supporter-workbook-form').hidden,true)});

Deno.test('verified sandbox entitlement is labeled test access and scheduled cancellation is explicit',async()=>{
 const f=fixture();await tick();f.setGetter(async()=>({data:{can_write:true,access_source:'sandbox',sandbox:true,access_until:'2027-01-01T00:00:00Z',cancellation_scheduled:true,entries:[]}}));
 f.document.getElementById('supporter-workbook-reload').click();await tick();
 const text=f.document.getElementById('supporter-workbook-status').textContent;
 assert.match(text,/Sandbox workbook test access/);assert.match(text,/Cancellation is scheduled/);assert.match(text,/No real paid membership is active/);assert.equal(f.document.getElementById('supporter-workbook-save').disabled,false);
 f.setGetter(async()=>({data:{can_write:false,access_source:'none',entries:[{reflection_number:1,answers:['saved test','',''],version:4}]}}));
 f.document.getElementById('supporter-workbook-reload').click();await tick();
 assert.equal(f.document.querySelector('#supporter-answer-fields textarea').value,'saved test');assert.equal(f.document.getElementById('supporter-workbook-save').disabled,true);assert.doesNotMatch(f.document.getElementById('supporter-workbook-status').textContent,/Sandbox workbook test access/);
});

Deno.test('billing sync automatically updates workbook cancellation without losing unsaved answers',async()=>{
 const {window}=parseHTML(html),{document}=window;
 document.querySelectorAll('.page').forEach(p=>p.classList.remove('active'));document.getElementById('page-supporter').classList.add('active');
 let scheduled=false,syncs=0;const calls=[];
 const client={auth:{getSession:async()=>({data:{session:{user:{id:'ADMIN'}}}}),onAuthStateChange(){}},functions:{invoke:async()=>{syncs++;return {data:{sandbox:true,updated:true}}}},rpc:async name=>{
 calls.push(name);
 if(name==='is_admin')return {data:true};
 if(name==='get_my_supporter_membership')return {data:[{sandbox:true,has_access:true,access_until:'2027-01-01T00:00:00Z',cancel_at_period_end:scheduled}]};
 if(name==='get_my_supporter_workbook')return {data:{can_write:true,access_source:'sandbox',access_until:'2027-01-01T00:00:00Z',cancellation_scheduled:scheduled,entries:[]}};
 throw Error('Unexpected RPC '+name);
 }};
 window.location={search:''};window.__fprSupabaseClient=client;window.confirm=()=>true;
 const memberStart=html.indexOf('(function initMembershipSandbox(){'),memberCode=html.slice(memberStart,html.indexOf('})();',memberStart)+5);
 new Function('window','document','CustomEvent','setTimeout','URL',data+memberCode+code)(window,document,window.CustomEvent,setTimeout,URL);
 await tick();await tick();assert.equal(syncs,1);assert.match(document.getElementById('supporter-sandbox-status').textContent,/Sandbox subscription verified/);
 const input=document.querySelector('#supporter-answer-fields textarea');input.value='KEEP MY UNSAVED DRAFT';input.dispatchEvent(new window.Event('input'));
 scheduled=true;document.querySelector('[data-member-action="sync"]').click();await tick();await tick();
 assert.equal(syncs,2);assert.match(document.getElementById('supporter-sandbox-status').textContent,/cancellation is scheduled/);
 assert.match(document.getElementById('supporter-workbook-status').textContent,/Cancellation is scheduled/);
 assert.equal(document.querySelector('#supporter-answer-fields textarea').value,'KEEP MY UNSAVED DRAFT');
 assert.match(document.getElementById('supporter-workbook-status').textContent,/unsaved answers are still here/);
});
Deno.test('access refresh failure preserves an unsaved workbook draft',async()=>{
 const f=fixture();await tick();const input=f.document.querySelector('#supporter-answer-fields textarea');input.value='KEEP ON NETWORK FAILURE';input.dispatchEvent(new f.window.Event('input'));
 f.setGetter(async()=>({error:{message:'offline'}}));f.document.dispatchEvent(new f.window.CustomEvent('fpr:membershipchange'));await tick();
 assert.equal(f.document.querySelector('#supporter-answer-fields textarea').value,'KEEP ON NETWORK FAILURE');assert.equal(f.document.getElementById('supporter-workbook-form').hidden,false);assert.equal(f.document.getElementById('supporter-workbook-save').disabled,true);
});
