/* Access labels are metadata only; workbook answers are never requested here. */
(function(){
 const client=window.__fprSupabaseClient,nodes=Array.from(document.querySelectorAll('[data-supporter-access-status]'));
 if(!nodes.length)return;
 let epoch=0,identity=null;
 const show=text=>nodes.forEach(node=>node.textContent=text);
 async function refresh(){const seq=++epoch;
  try{if(!client)throw Error('unavailable');const session=await client.auth.getSession();if(seq!==epoch)return;const id=session.data?.session?.user?.id;if(!id){identity=null;show('Sign in to check your supporter access. Free recovery tools remain available.');return;}identity=id;
   const [access,founding]=await Promise.all([client.rpc('get_my_supporter_benefits'),client.rpc('get_supporter_founding_offer')]);if(seq!==epoch)return;if(access.error)throw access.error;
   const data=access.data || {},end=data.access_until?new Date(data.access_until).toLocaleDateString():null;
   if(data.can_write && data.access_source==='sandbox'){show('Test access only'+(end?' · Through '+end:'')+'. No paid membership is active.');return;}
   if(data.can_write && data.access_source==='admin'){show('Administrator access · Workbook and card collection available.');return;}
   if(data.can_write){const isFounding=!founding.error && Date.parse(founding.data?.access_until)>Date.now() && data.access_source==='no_charge';show('Porch Supporter active · '+(isFounding?'Free founding year':data.access_source==='paid'?'Paid membership':'No-charge access')+(end?' · Through '+end:'')+'. Workbook and card collection included.');}
   else show('Full supporter access is not active. The workbook preview and your free recovery tools remain available.');
  }catch(_){if(seq===epoch)show('Could not confirm supporter access. Reopen Account or the workbook when connected to refresh.');}
 }
 client?.auth.onAuthStateChange((_event,session)=>{const next=session?.user?.id || null;if(next!==identity){++epoch;identity=next;show(next?'Checking supporter access…':'Sign in to check your supporter access.');setTimeout(refresh,0);}});
 document.addEventListener('fpr:pagechange',e=>{if(['workbook','supporter'].includes(e.detail?.page))refresh();});
 document.addEventListener('fpr:membershipchange',refresh);
 document.querySelectorAll('[data-account-action="open"]').forEach(button=>button.addEventListener('click',refresh));
 refresh();
})();
