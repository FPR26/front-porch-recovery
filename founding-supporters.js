/* Founding enrollment shares no-charge benefits; never starts billing. */
(function(){
  const panels=Array.from(document.querySelectorAll('[data-founding-offer]'));
  const admin=document.getElementById('founding-admin');
  if(!panels.length && !admin)return;
  let client;try{client=window.supabase.createClient('https://ptmazxslypzslhhcqudn.supabase.co','sb_publishable_1_TI_W8Zuk9319d-akZYrw_uAEVBtz8',{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}});}catch(_){return;}
  let user=null,epoch=0,busy=false,offer=null,isAdmin=false;
  function message(text){document.querySelectorAll('[data-founding-status]').forEach(el=>el.textContent=text);}
  function controls(){document.querySelectorAll('[data-founding-claim],[data-founding-open],[data-founding-close]').forEach(el=>el.disabled=busy);}
  function render(){
    for(const panel of panels){
      panel.hidden=!offer || (!offer.enrollment_open && !offer.claimed_at);
      const button=panel.querySelector('[data-founding-claim]');button.hidden=!offer?.enrollment_open || !!offer?.claimed_at;
      button.textContent=user?'Claim my free year':'Sign in to claim my free year';
    }
    if(offer?.claimed_at)message('Your founding year was claimed on '+new Date(offer.claimed_at).toLocaleDateString()+'. Its end date is '+new Date(offer.access_until).toLocaleDateString()+'. View your current access in the workbook.');
    else message(offer?.enrollment_open?'Enrollment is open. Your 365 days begin when you claim. One founding year per account.':'Founding enrollment is closed. Previously granted access keeps its end date.');
    if(admin){admin.hidden=!isAdmin;const status=admin.querySelector('[data-founding-admin-status]');status.textContent=offer?(offer.enrollment_open?'Enrollment is OPEN. ':'Enrollment is CLOSED. ')+(offer.claim_count??0)+' founding years claimed. Paid checkout is unchanged.':'Could not load enrollment settings.';}
    controls();
  }
  async function load(){
    const seq=++epoch;
    try{const session=await client.auth.getSession();if(seq!==epoch)return;user=session.data?.session?.user || null;
      const result=await client.rpc('get_supporter_founding_offer');if(seq!==epoch)return;if(result.error)throw result.error;offer=result.data;
      if(admin){const check=await client.rpc('is_admin');if(seq!==epoch)return;isAdmin=!check.error && check.data===true;}
      render();
    }catch(_){if(seq!==epoch)return;offer=null;panels.forEach(p=>p.hidden=true);if(admin){admin.hidden=false;admin.querySelector('[data-founding-admin-status]').textContent='Founding enrollment is not connected yet. No access was changed.';admin.querySelectorAll('[data-founding-open],[data-founding-close]').forEach(b=>b.disabled=true);}}
  }
  document.querySelectorAll('[data-founding-claim]').forEach(button=>button.addEventListener('click',async()=>{
    if(busy || !offer?.enrollment_open || offer.claimed_at)return;
    if(!user){document.getElementById('header-account-btn')?.click();return;}
    busy=true;controls();message('Claiming your free year…');const seq=epoch;
    try{const result=await client.rpc('claim_my_founding_supporter_year');if(seq!==epoch)return;if(result.error)throw result.error;offer=result.data;render();document.dispatchEvent(new CustomEvent('fpr:pagechange',{detail:{page:'supporter'}}));}
    catch(err){if(seq===epoch)message(err?.code==='55000'?'Enrollment is closed or temporarily under maintenance. Refresh before trying again.':'Could not confirm your claim. Refresh to check your status before trying again.');}
    finally{if(seq===epoch){busy=false;controls();}}
  }));
  if(admin)for(const [selector,open]of [['[data-founding-open]',true],['[data-founding-close]',false]])admin.querySelector(selector).addEventListener('click',async()=>{
    if(busy || !isAdmin)return;
    if(!window.confirm(open?'Open founding enrollment? Confirmed members can claim 365 days of workbook and card collection access free. No card or automatic billing.':'Close founding enrollment? Previously granted years remain available through their end dates.'))return;
    busy=true;controls();const seq=epoch;
    try{const result=await client.rpc('admin_set_supporter_founding_offer',{p_open:open});if(seq!==epoch)return;if(result.error)throw result.error;offer=result.data;render();}
    catch(_){if(seq===epoch)admin.querySelector('[data-founding-admin-status]').textContent='Could not confirm this change. Refresh enrollment status before retrying.';}
    finally{if(seq===epoch){busy=false;controls();}}
  });
  document.querySelectorAll('[data-founding-refresh]').forEach(button=>button.addEventListener('click',()=>{if(!busy)load();}));
  client.auth.onAuthStateChange((_event,session)=>{const next=session?.user?.id || null;if(next!==(user?.id || null)){++epoch;user=null;offer=null;isAdmin=false;busy=false;panels.forEach(p=>p.hidden=true);if(admin)admin.hidden=true;setTimeout(load,0);}});
  document.addEventListener('fpr:pagechange',e=>{if(e.detail?.page==='supporter' && !busy)load();});
  load();
})();
