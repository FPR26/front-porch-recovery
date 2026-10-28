/* Public section status; admin authority is always checked by RPC. */
(function(root){
'use strict';
const sections={community:'Community',checkin:'Check In',history:'Recovery History',journal:'Journal',weekly:'Weekly Review',milestones:'Milestones & Wins',progress:'Progress',today:'Today',myrecovery:'My Recovery',resources:'Resources',recoveryplan:'My Recovery Plan',meetings:'Meetings & Support',porch:'The Porch',books:'Books',shop:'Porch Shop',supporter:'Porch Supporter',toolbox:'Recovery Toolbox',daily:'Daily Porch',music:'Music',stories:'Porch Stories',about:'Our Story'};
const aliases={porchtopic:'porch',resource:'resources',story:'stories','story-submit':'stories'};
const keyFor=id=>Object.prototype.hasOwnProperty.call(aliases,id)?aliases[id]:(Object.prototype.hasOwnProperty.call(sections,id)?id:null);
const message='This section is under maintenance. Please check back soon.';
function createController(win,doc){
 let client=null,rows=new Map(),loaded=false,admin=false,epoch=0,requested=null,timer=null,identity=null,shown=false,refreshRevision=0;
 function bounded(p){return new Promise((resolve,reject)=>{const timeout=setTimeout(()=>reject(Error('Status unavailable')),5000);Promise.resolve(p).then(v=>{clearTimeout(timeout);resolve(v);},e=>{clearTimeout(timeout);reject(e);});});}
 function notice(){const n=doc.getElementById('maintenance-admin-preview');const row=rows.get(keyFor(requested?.id));n.hidden=!(row?.enabled && admin);n.textContent=n.hidden?'':'Admin preview: this section is under maintenance for visitors.';}
 function draw(checking){
  const row=rows.get(keyFor(requested?.id)),title=doc.getElementById('maintenance-title');
  title.textContent=checking?'Checking section availability…':(sections[keyFor(requested?.id)] || 'This section')+' is under maintenance';
  doc.getElementById('maintenance-message').textContent=checking?'One moment, please.':row?.message || message;
  if(!shown){shown=true;win.goTo('maintenance',{maintenanceInternal:true,skipHashUpdate:true});title.focus();}
 }
 function reconcile(){
  if(!requested || !loaded)return;
  const row=rows.get(keyFor(requested.id));
  if(row?.enabled && !admin){draw(false);return;}
  if(shown){shown=false;win.goTo(requested.id,Object.assign({},requested.opts,{maintenanceInternal:true}));}
  notice();
 }
 async function refresh(){
  if(!client)return;
  const version=epoch,request=++refreshRevision;
  try{const r=await bounded(client.rpc('get_section_maintenance'));if(version!==epoch || request!==refreshRevision || r.error)return;rows=new Map((r.data || []).filter(r=>keyFor(r.section_key)===r.section_key).map(r=>[r.section_key,r]));}
  catch(_){} // Keep last good status. First-load failure leaves free tools available.
  finally{if(version===epoch && request===refreshRevision){loaded=true;reconcile();}}
 }
 function route(id,opts){
  if(opts?.maintenanceInternal)return true;
  requested={id,opts:opts || {}};shown=false;notice();
  if(!keyFor(id))return true;
  if(!loaded || (rows.get(keyFor(id))?.enabled && !admin)){
   if(!opts?.skipHashUpdate){try{win.history.replaceState(null,'','#'+id);}catch(_){}}
   draw(!loaded);return false;
  }
  return true;
 }
 async function sessionChanged(session){
  const next=session?.user?.id || null;if(next===identity && loaded)return;
  identity=next;const version=++epoch;admin=false;loaded=false;notice();
  if(requested && rows.get(keyFor(requested.id))?.enabled)draw(false);
  if(next){try{const r=await bounded(client.rpc('is_admin'));if(version!==epoch)return;admin=!r.error && r.data===true;}catch(_){}}
  if(version===epoch)await refresh();
 }
 function connect(value){
  client=value;if(!client){loaded=true;reconcile();return;}
  let authEventSeen=false;
  client.auth.onAuthStateChange((_event,session)=>{authEventSeen=true;Promise.resolve().then(()=>sessionChanged(session));});
  bounded(client.auth.getSession()).then(r=>{if(!authEventSeen)return sessionChanged(r.data?.session);}).catch(()=>{if(!authEventSeen){loaded=true;refresh();}});
  timer=win.setInterval(()=>{if(doc.visibilityState!=='hidden')refresh();},60000);
  doc.addEventListener('visibilitychange',()=>{if(doc.visibilityState==='visible')refresh();});
  win.addEventListener('pagehide',()=>{win.clearInterval(timer);});
  win.addEventListener('pageshow',e=>{if(e.persisted){timer=win.setInterval(()=>{if(doc.visibilityState!=='hidden')refresh();},60000);refresh();}});
 }
 doc.addEventListener('submit',event=>{const page=event.target.closest?.('.page');if(!admin && rows.get(keyFor(page?.id.replace(/^page-/,'')))?.enabled){event.preventDefault();event.stopImmediatePropagation();draw(false);}},true);
 return {route,connect,refresh};
}
root.FPRMaintenanceDefinitions={sections,aliases,keyFor,message};
root.FPRMaintenance=createController(root,root.document);
})(window);
