/* FPR updates: public release metadata only. Never reload automatically or persist drafts. */
(function(){
  'use strict';
  const guards=new Map(),tracked=new Map();
  const excluded=new Set(['mr-log-form','mr-goal-form','rp-form','jr-editor','wr-form','supporter-workbook-form','account-profile-form','daily-jump-form']);
  let registration=null,latest=null,lastCheck=0,pendingCheck=null,applying=false,dismissed=null,started=false;
  const version=document.querySelector('meta[name="fpr-app-version"]')?.content || 'unknown';
  const build=Number(document.querySelector('meta[name="fpr-app-build"]')?.content || 0);
  const base=new URL('./',window.location.href);
  function message(text){const node=document.getElementById('app-update-status');if(node)node.textContent=text;}
  function checkMessage(text){const node=document.getElementById('app-update-check-status');if(node)node.textContent=text;}
  function controls(busy){document.querySelectorAll('[data-fpr-update-apply]').forEach(b=>b.disabled=busy);}
  function key(){return String(latest?.build || build)+(registration?.waiting?':worker':'');}
  function showNotice(){const notice=document.getElementById('app-update-notice');if(!notice)return;const available=!!(latest && latest.build>build || registration?.waiting);notice.hidden=!available || dismissed===key();}
  function signature(form){return JSON.stringify(Array.from(form.querySelectorAll('input,textarea,select')).filter(c=>!['submit','button','password','hidden','file','search'].includes(c.type)).map(c=>[c.name||c.id,c.type==='checkbox'||c.type==='radio'?c.checked:c.value]));}
  function eligible(form){return form && !excluded.has(form.id) && form.getAttribute('role')!=='search' && !/search/i.test(form.id);}
  function remember(event){const form=event.target.closest?.('form');if(eligible(form) && !tracked.has(form))tracked.set(form,{value:signature(form),forced:false});}
  document.addEventListener('focusin',remember,true);
  ['input','change'].forEach(name=>document.addEventListener(name,event=>{const form=event.target.closest?.('form');if(eligible(form) && !tracked.has(form))tracked.set(form,{value:null,forced:true});},true));
  document.addEventListener('reset',event=>{const form=event.target;if(tracked.has(form))setTimeout(()=>{if(!event.defaultPrevented)tracked.delete(form);},0);},true);
  function blockers(){
    const found=[];
    guards.forEach((fn,name)=>{try{if(fn())found.push(name);}catch(_){found.push(name);}});
    tracked.forEach((initial,form)=>{
      if(!form.isConnected){tracked.delete(form);return;}
      if(form.closest('[hidden]'))return;
      for(let node=form;node;node=node.parentElement){if(node.style?.display==='none')return;}
      if(initial.forced || signature(form)!==initial.value){const label=form.closest('.page')?.querySelector('h1')?.textContent || (form.closest('#account-modal')?'Account':'a form');if(!found.includes(label))found.push(label);}
    });
    return found;
  }
  function blocked(){const names=blockers();if(!names.length)return false;message('You have unsaved writing or a save in progress in '+names.join(', ')+'. Save or cancel it before updating. Nothing has been reloaded.');return true;}
  async function release(){
    const response=await window.fetch(new URL('app-version.json',base).href,{cache:'no-store',credentials:'omit',redirect:'error'});
    if(!response.ok)throw Error('release unavailable');
    const data=await response.json();
    if(!Number.isSafeInteger(data.build) || data.build<1 || typeof data.version!=='string' || !/^[A-Za-z0-9.\-]{1,60}$/.test(data.version))throw Error('invalid release');
    return data;
  }
  async function check(options={}){
    if(pendingCheck)return pendingCheck;
    if(!options.force && Date.now()-lastCheck<60000)return;
    lastCheck=Date.now();
    pendingCheck=(async()=>{
      try{
        if(window.navigator.onLine===false)throw Error('offline');
        if(options.force && registration?.update)await registration.update().catch(()=>{});
        latest=await release();if(options.force)dismissed=null;showNotice();
        if(options.force)checkMessage(latest.build>build || registration?.waiting?'An update is available. Use Update app when your writing is saved.':latest.build===build?'You are using the current version: '+version+'.':'The newest release is still being published. Please check again later.');
      }catch(_){if(options.force)checkMessage('Could not check for updates. Your current app is still available. Try again when connected.');}
    })().finally(()=>{pendingCheck=null;});return pendingCheck;
  }
  async function activateWaiting(){
    const worker=registration?.waiting;if(!worker)return true;
    return await new Promise(resolve=>{
      let ended=false;
      function finish(ok){if(ended)return;ended=true;clearTimeout(timer);window.navigator.serviceWorker.removeEventListener('controllerchange',changed);resolve(ok);}
      function changed(){finish(true);}
      const timer=setTimeout(()=>finish(false),8000);
      window.navigator.serviceWorker.addEventListener('controllerchange',changed);
      try{worker.postMessage({type:'FPR_APPLY_UPDATE'});}catch(_){finish(false);}
    });
  }
  async function apply(){
    if(applying)return;
    if(blocked())return;
    applying=true;controls(true);message('Checking the update before reloading…');
    try{
      if(window.navigator.onLine===false)throw Error('offline');
      const target=await release();
      if(target.build<build)throw Error('publishing');
      const response=await window.fetch(new URL('index.html',base).href,{cache:'reload',credentials:'omit',redirect:'error'});
      if(!response.ok)throw Error('page unavailable');
      const page=new DOMParser().parseFromString(await response.text(),'text/html');
      if(Number(page.querySelector('meta[name="fpr-app-build"]')?.content)!==target.build || page.querySelector('meta[name="fpr-app-version"]')?.content!==target.version)throw Error('publishing');
      if(blocked())return;
      if(!await activateWaiting())throw Error('activation timeout');
      // A member can begin writing while the network or worker is preparing. Check again.
      if(blocked())return;
      message('No unsaved writing found. Reloading the app…');
      window.location.reload();
    }catch(_){message('The update could not finish. Nothing was reloaded. Your writing is still here; try again when connected.');}
    finally{applying=false;controls(false);}
  }
  function connect(reg){
    if(registration===reg)return;registration=reg;showNotice();
    reg.addEventListener?.('updatefound',()=>{const worker=reg.installing;worker?.addEventListener('statechange',()=>{if(worker.state==='installed'){showNotice();check({force:true});}});});
  }
  function start(){
    if(started)return;started=true;
    document.querySelectorAll('[data-fpr-version]').forEach(node=>node.textContent='Version '+version);
    document.querySelectorAll('[data-fpr-update-apply]').forEach(button=>button.addEventListener('click',apply));
    document.querySelectorAll('[data-fpr-update-check]').forEach(button=>button.addEventListener('click',()=>check({force:true})));
    document.getElementById('app-update-later')?.addEventListener('click',()=>{dismissed=key();showNotice();});
    document.addEventListener('visibilitychange',()=>{if(!document.hidden)check();});
    window.addEventListener('online',()=>check({force:true}));
    window.addEventListener('beforeunload',event=>{if(blockers().length){event.preventDefault();event.returnValue='';}});
    if(/^https?:$/.test(window.location.protocol)){
      check();setInterval(()=>{if(!document.hidden)check();},600000);
    }
  }
  window.FPRUpdates={guard:(name,fn)=>guards.set(name,fn),blockers,check,apply,connect};
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
})();
