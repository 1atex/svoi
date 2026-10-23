'use strict';
async function shareProfile(){
 const ownerToken=token,content=el('div');content.append(el('p','','Подготавливаем профиль…'));dialog('Поделиться профилем',content);
 try{
  const result=await api('transfer/export','POST');if(!content.isConnected||token!==ownerToken)return;
  const intro=el('p','',`«${result.name}»: подписок по ссылке — ${result.remoteSources}, встроенных серверов — ${result.servers}. На другом устройстве откройте SVOI → «Получить профиль».`);
  const label=el('label','','Код профиля'),code=el('textarea','transfer-code');code.readOnly=true;code.spellcheck=false;code.value=result.code;label.append(code);
  const actions=el('div','button-row'),copy=el('button','primary','Копировать код'),download=el('button','secondary','Сохранить .svoi');copy.prepend(icon('copy'));copy.onclick=()=>clipboard(result.code);download.prepend(icon('download'));download.onclick=()=>saveBlob(new Blob([result.code+'\n'],{type:'text/plain;charset=utf-8'}),'svoi-profile.svoi');actions.append(copy,download);
  content.replaceChildren(intro,label,actions,el('p','privacy-note','Код и файл содержат доступ к подпискам. Передавайте их лично. Код многоразовый, без срока действия; устройства работают независимо, без автоматической синхронизации и удалённого отзыва.'));
 }catch(e){if(content.isConnected)content.replaceChildren(el('p','form-error',e.message));}
}
function profileFileInput(file,text,error){
 file.onchange=async()=>{const selected=file.files[0];if(!selected)return;error.textContent='';if(selected.size>12*1024*1024){error.textContent='Максимальный размер файла — 12 МБ';file.value='';return;}try{text.value=(await selected.text()).trim();}catch{error.textContent='Не удалось прочитать файл';}};
}
function receiveProfile(){
 const form=el('form');form.append(el('p','','Вставьте код с другого устройства или выберите файл .svoi. Перед сохранением вы увидите состав профиля.'));
 const label=el('label','','Код профиля'),code=el('textarea');code.required=true;code.spellcheck=false;code.placeholder='SVOI1.…';label.append(code);
 const fileLabel=el('label','','Или файл .svoi'),file=el('input');file.type='file';file.accept='.svoi,.txt';fileLabel.append(file);
 const deviceLabel=el('label','','Это устройство'),device=el('input');device.required=true;device.maxLength=60;device.value=group?.devices.find(d=>d.id===group.self)?.name||'Мой ПК';deviceLabel.append(device);
 const error=el('p','form-error');error.setAttribute('role','alert');const submit=el('button','primary','Продолжить');submit.type='submit';form.append(label,fileLabel,deviceLabel,error,submit);profileFileInput(file,code,error);
 form.onsubmit=async e=>{e.preventDefault();error.textContent='';try{await busy(submit,()=>previewTransfer({code:code.value,deviceName:device.value,platform:detectPlatform()}));}catch(e){error.textContent=e.message;}};dialog('Получить профиль',form);
}
async function previewTransfer(data){
 const contextToken=token,contextGroup=group?.id;
 const preview=await api('transfer/preview','POST',{code:data.code});
 const content=el('div','transfer-preview');content.append(el('h3','',preview.name));
 const facts=el('dl','transfer-facts');for(const [title,value]of [['HWID',preview.hwid],['Подписок / импортов',preview.sources.length],['Серверов в файле',preview.servers]])facts.append(el('dt','',title),el('dd','',String(value)));content.append(facts);
 const sources=el('ul','transfer-sources');preview.sources.forEach(s=>sources.append(el('li','',`${s.name} · ${s.remote?'загрузится с '+s.host:'серверов: '+s.count}`)));content.append(sources);
 content.append(el('p','','Сохранятся общий HWID, OS и другие параметры запроса. После подтверждения подписки загрузятся по ссылкам на этом ПК с общим профилем. Конфигурации без ссылки перенесутся из файла.'));
 const actions=el('div','dialog-actions'),cancel=el('button','secondary','Отмена'),create=el('button','primary',preview.sources.some(s=>s.remote)?'Добавить и загрузить':'Добавить профиль'),error=el('p','form-error');error.setAttribute('role','alert');cancel.onclick=()=>$('#modal').close();
 const save=async(replace,button)=>{error.textContent='';try{await busy(button,async()=>{
  if(contextToken!==token||contextGroup!==group?.id)throw Error('Текущий профиль изменился. Откройте импорт заново.');
  actions.querySelectorAll('button').forEach(b=>b.disabled=true);
  const result=await api('transfer/import','POST',{...data,replace});
  if(replace){group=result.group;const session=sessions.find(s=>s.token===token);if(session)session.name=group.name+' / '+group.devices.find(d=>d.id===group.self).name;remember();render();}
  else acceptSession(result);
  const remoteSources=(group.subscriptions||[]).filter(s=>s.remote);
  if(remoteSources.length)await refreshTransferredSources(remoteSources);
  else {$('#modal').close();toast(replace?'Профиль обновлён. Переподключите VPN, чтобы применить изменения.':'Профиль перенесён. Выберите сервер и подключитесь.');}
 });}catch(e){error.textContent=e.message;}finally{actions.querySelectorAll('button').forEach(b=>b.disabled=false);}};
 create.onclick=()=>save(false,create);actions.append(cancel,create);
 if(group?.owner){const replace=el('button','secondary','Заменить текущий профиль');replace.onclick=()=>{
  const confirmation=el('div');confirmation.append(el('p','',`Заменить HWID и все подписки профиля «${group.name}» данными «${preview.name}»? Локальные сеансы сохранятся. Запущенный VPN применит изменения после переподключения.`));const buttons=el('div','dialog-actions'),back=el('button','secondary','Назад'),confirm=el('button','primary','Заменить профиль');back.onclick=()=>dialog('Получить профиль',content);confirm.onclick=()=>{dialog('Получить профиль',content);save(true,replace);};buttons.append(back,confirm);confirmation.append(buttons);dialog('Заменить профиль?',confirmation);
 };actions.append(replace);}
 content.append(error,actions);dialog('Получить профиль',content);
}
profileFileInput($('#welcome-profile-file'),$('#join-form [name="code"]'),$('#join-form .form-error'));
$$('.receive-profile-button').forEach(b=>b.onclick=receiveProfile);

async function refreshTransferredSources(sources){
 const auth=token,gid=group.id,content=el('div'),intro=el('p','','Профиль сохранён. Загружаем подписки на этом ПК с общими HWID, OS, Model, Locale и User-Agent.');
 const list=el('div','transfer-downloads'),actions=el('div','dialog-actions'),retry=el('button','secondary','Повторить неудавшиеся'),done=el('button','primary','Готово'),stop=el('button','secondary','Остановить');
 const entries=sources.map(source=>{const row=el('div','subscription-row'),info=el('div','subscription-info'),status=el('span','','Ожидает загрузки');info.append(el('strong','',source.name),status);row.append(info);list.append(row);return {source,status,ok:false};});
 actions.append(stop,retry,done);content.append(intro,list,actions);dialog('Загрузка подписок',content);
 let controller=null;
 const close=()=>controller?.abort();$('#modal').addEventListener('close',close,{once:true});
 done.onclick=()=>$('#modal').close();stop.onclick=()=>controller?.abort();
 const run=async()=>{
  controller=new AbortController();retry.hidden=true;done.disabled=true;stop.hidden=false;let cancelled=false;
  try{for(const entry of entries){
   if(entry.ok)continue;
   if(controller.signal.aborted||token!==auth||group?.id!==gid){cancelled=true;break;}
   entry.status.textContent='Загрузка…';entry.status.classList.remove('form-error');
   try{
    const response=await fetch('/api/subscription/refresh?id='+encodeURIComponent(entry.source.id),{method:'POST',headers:{Authorization:'Bearer '+auth},signal:controller.signal});
    const result=await response.json();if(!response.ok)throw Error(result.error||'Не удалось загрузить подписку');
    entry.ok=true;entry.status.textContent=`Загружено серверов: ${result.count}`;
   }catch(e){entry.status.textContent=e.name==='AbortError'?'Загрузка остановлена':e.message;entry.status.classList.add('form-error');if(e.name==='AbortError'){cancelled=true;break;}}
  }
  if(token===auth&&group?.id===gid)await load();
  const loaded=entries.filter(e=>e.ok).length;
  intro.textContent=loaded===entries.length?'Подписки загружены. Выберите сервер и подключитесь. Если VPN уже был запущен, переподключите его.':`Загружено ${loaded} из ${entries.length}. ${cancelled?'Проверка остановлена. ':''}Ссылки сохранены: повторите загрузку здесь или кнопкой обновления подписки.`;
  }catch(e){intro.textContent='Профиль сохранён, но не удалось обновить интерфейс: '+e.message;}
  finally{stop.hidden=true;done.disabled=false;retry.hidden=entries.every(e=>e.ok)||token!==auth||group?.id!==gid;}
 };
 retry.onclick=run;await run();
}
