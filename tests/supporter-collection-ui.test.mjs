import {parseHTML} from 'npm:linkedom@0.18.12';
import fs from 'node:fs';import assert from 'node:assert/strict';
const html=fs.readFileSync(new URL('../index.html',import.meta.url),'utf8'),start=html.indexOf('(function initSupporterCollection(){'),code=html.slice(start,html.indexOf('})();',start)+5);
const tick=()=>new Promise(resolve=>setTimeout(resolve,10));
function fixture({user='A',access={can_write:true,access_source:'no_charge',access_until:'2027-01-01T00:00:00Z'}}={}){
 const {window}=parseHTML(html),{document}=window;document.getElementById('page-supporter').classList.add('active');
 const canvas=document.getElementById('supporter-collection-preview'),calls=[],downloads=[],revoked=[];let onAuth,identity=user,benefits=access,invoke=async()=>({data:{svg:'<svg/>',logo:'data:image/png;base64,fixture',filename:'fpr-light-collection.png'}}),draws=0;
 canvas.getContext=()=>({clearRect(){},drawImage(){draws++}});canvas.toBlob=callback=>callback(new Blob(['fixture-png'],{type:'image/png'}));
 const select=document.getElementById('supporter-collection-design');Object.defineProperty(select,'value',{value:'light',writable:true});Object.defineProperty(select,'options',{value:[{text:'Porch Light'}]});Object.defineProperty(select,'selectedIndex',{value:0});
 window.HTMLAnchorElement.prototype.click=function(){downloads.push(this.download)};
 const client={auth:{getSession:async()=>({data:{session:identity?{user:{id:identity}}:null}}),onAuthStateChange:fn=>onAuth=fn},rpc:async(name)=>{calls.push(name);return {data:benefits}},functions:{invoke:async(name,args)=>{calls.push({name,args});return await invoke()}}};
 window.__fprSupabaseClient=client;
 class Image {set src(value){queueMicrotask(()=>this.onload())}}
 const url={createObjectURL:()=> 'blob:fixture',revokeObjectURL:value=>revoked.push(value)};
 new Function('window','document','CustomEvent','Image','URL','Blob','setTimeout',code)(window,document,window.CustomEvent,Image,url,Blob,(fn)=>queueMicrotask(fn));
 return {document,calls,downloads,revoked,draws:()=>draws,setInvoke:fn=>invoke=fn,setAccess:value=>benefits=value,changeUser:id=>{identity=id;onAuth('SIGNED_OUT',id?{user:{id}}:null)},refresh:()=>document.dispatchEvent(new window.CustomEvent('fpr:membershipchange'))};
}
Deno.test('signed-out and inactive members have free samples but no collection controls',async()=>{
 const signedOut=fixture({user:null});await tick();assert.equal(signedOut.calls.length,0);assert.equal(signedOut.document.getElementById('supporter-benefits-controls').hidden,true);assert.equal(signedOut.document.querySelectorAll('[data-supporter-download]').length,6);
 const inactive=fixture({access:{can_write:false}});await tick();assert.equal(inactive.document.getElementById('supporter-benefits-controls').hidden,true);assert.match(inactive.document.getElementById('supporter-benefits-status').textContent,/not active/);
});
Deno.test('authorized member downloads a clean PNG only through authenticated endpoint',async()=>{
 const f=fixture();await tick();assert.match(f.document.getElementById('supporter-benefits-status').textContent,/No-charge/);assert.equal(f.document.getElementById('supporter-benefits-controls').hidden,false);
 f.document.getElementById('supporter-collection-download').click();await tick();assert.deepEqual(f.downloads,['fpr-light-collection.png']);assert.equal(f.draws(),2);assert.equal(f.document.getElementById('supporter-collection-preview').hidden,false);assert(f.calls.some(c=>c.name==='supporter-cards' && c.args.body.design==='light'));assert(f.revoked.length>=2);
});
Deno.test('signout suppresses a pending download and clears the collection preview',async()=>{
 const f=fixture();await tick();let resolve;f.setInvoke(()=>new Promise(r=>resolve=r));f.document.getElementById('supporter-collection-download').click();f.changeUser(null);resolve({data:{svg:'<svg/>',logo:'data:image/png;base64,fixture',filename:'fpr-light-collection.png'}});await tick();assert.equal(f.downloads.length,0);assert.equal(f.document.getElementById('supporter-benefits-controls').hidden,true);assert.equal(f.document.getElementById('supporter-collection-preview').hidden,true);
});
Deno.test('revocation, server denial and unavailable access cannot leave download enabled',async()=>{
 const f=fixture();await tick();f.setAccess({can_write:false});f.refresh();await tick();assert.equal(f.document.getElementById('supporter-collection-download').disabled,true);
 f.setAccess({can_write:true,access_source:'sandbox',cancellation_scheduled:true,access_until:'2027-01-01T00:00:00Z'});f.refresh();await tick();assert.match(f.document.getElementById('supporter-benefits-status').textContent,/Sandbox/);assert.match(f.document.getElementById('supporter-benefits-status').textContent,/Cancellation is scheduled/);
 f.setInvoke(async()=>({error:{message:'forbidden'}}));f.document.getElementById('supporter-collection-download').click();await tick();assert.equal(f.downloads.length,0);assert.equal(f.document.getElementById('supporter-benefits-controls').hidden,true);
 f.setAccess(null);f.refresh();await tick();assert.match(f.document.getElementById('supporter-benefits-status').textContent,/could not be checked/);
});
