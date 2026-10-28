/* Admin-only section controls; public status contains no member data. */
(function(win,doc){
'use strict';let mounted=false,epoch=0,identity=null;
win.FPRMaintenanceAdmin={mount(client){
 if(mounted)return;mounted=true;
 const panel=doc.getElementById('section-maintenance-controls'),list=doc.getElementById('section-maintenance-list'),status=doc.getElementById('section-maintenance-status'),refresh=doc.getElementById('section-maintenance-refresh');
 const defs=win.FPRMaintenanceDefinitions;
 function clear(){++epoch;list.replaceChildren();status.textContent='';panel.open=false;}
 client.auth.onAuthStateChange((_event,session)=>{const id=session?.user?.id || null;if(id!==identity){identity=id;clear();}});
 async function load(){
  const version=++epoch;status.textContent='Loading section settings…';refresh.disabled=true;
  try{
   const permission=await client.rpc('is_admin');if(version!==epoch)return;
   if(permission.error || permission.data!==true)throw Error('Admin access is required.');
   const result=await client.rpc('get_section_maintenance');if(version!==epoch)return;if(result.error)throw Error('Maintenance controls are not connected yet.');
   list.replaceChildren();
   for(const row of result.data || []){
    if(!Object.prototype.hasOwnProperty.call(defs.sections,row.section_key))continue;
    const card=doc.createElement('form');card.className='maintenance-setting';
    const title=doc.createElement('h3');title.textContent=defs.sections[row.section_key];card.appendChild(title);
    const current=doc.createElement('p');current.textContent=row.enabled?'Currently under maintenance':'Currently available';card.appendChild(current);
    const label=doc.createElement('label');label.textContent='Section status';
    const choice=doc.createElement('select');choice.id='maintenance-choice-'+row.section_key;label.htmlFor=choice.id;
    for(const [value,text]of [['available','Available'],['maintenance','Under maintenance']]){const option=doc.createElement('option');option.value=value;option.textContent=text;option.selected=(row.enabled?value==='maintenance':value==='available');choice.appendChild(option);}
    card.append(label,choice);
    const textLabel=doc.createElement('label');textLabel.textContent='Message for visitors';
    const text=doc.createElement('textarea');text.id='maintenance-text-'+row.section_key;textLabel.htmlFor=text.id;text.maxLength=500;text.required=true;text.value=row.message;card.append(textLabel,text);
    const save=doc.createElement('button');save.type='submit';save.className='btn btn-small';save.textContent='Save '+defs.sections[row.section_key];card.appendChild(save);
    const feedback=doc.createElement('p');feedback.setAttribute('role','status');card.appendChild(feedback);
    card.addEventListener('submit',async event=>{
     event.preventDefault();const enabled=choice.value==='maintenance';
     if(!text.value.trim()){feedback.textContent='Enter a message for visitors.';return;}
     if(!win.confirm((enabled?'Put ':'Reopen ')+defs.sections[row.section_key]+(enabled?' under maintenance? Other sections stay available.':' for visitors?')))return;
     const requestEpoch=epoch;save.disabled=true;
     try{
      const result=await client.rpc('admin_set_section_maintenance',{p_section:row.section_key,p_enabled:enabled,p_message:text.value.trim(),p_version:row.version});
      if(requestEpoch!==epoch)return;
      if(result.error)throw Error(result.error.code==='40001'?'Another admin changed this setting. Reload settings before saving.':'The change could not be saved. Reload settings and try again.');
      row.enabled=enabled;row.message=text.value.trim();row.version+=1;
      current.textContent=enabled?'Currently under maintenance':'Currently available';feedback.textContent='Saved. Open app tabs update within one minute or when brought back into view.';
     }catch(error){if(requestEpoch===epoch)feedback.textContent=error.message;}
     finally{if(requestEpoch===epoch)save.disabled=false;}
    });
    list.appendChild(card);
   }
   status.textContent='Settings loaded. Nothing changes until you save a section.';
  }catch(error){if(version===epoch){list.replaceChildren();status.textContent=error.message;}}
  finally{if(version===epoch)refresh.disabled=false;}
 }
 refresh.addEventListener('click',load);panel.addEventListener('toggle',()=>{if(panel.open)load();});
}};
})(window,document);
