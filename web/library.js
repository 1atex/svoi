'use strict';
const serverProbes=new Map();
let probeRunning=false,probeAbort=null;

function renderSubscriptions(){
 const sources=group.subscriptions||[];const list=$('#subscription-list');list.replaceChildren();
 $('#subscription-status').textContent=sources.length?String(sources.length):'Нет подписок';$('#subscription-status').classList.toggle('green',!!sources.length);
 $('#subscription-description').textContent='Добавьте ссылку подписки или импортируйте файл.';$('#subscription-description').hidden=!!sources.length;
 $('#subscription-stats').hidden=true;$('#refresh-subscription').hidden=true;$('#download-subscription').hidden=true;
 $('#add-subscription').hidden=!group.owner;$('#add-subscription').replaceChildren(icon('plus'),document.createTextNode('Добавить подписку'));
 const warnings=[];sources.forEach(source=>{
  const row=el('div','subscription-row'),info=el('div','subscription-info');
  info.append(el('strong','',source.name),el('span','',`${source.count} ${pluralRU(source.count,'сервер','сервера','серверов')}${source.host&&source.host!==source.name?' · '+source.host:!source.remote?' · Из файла':''}`));
  info.append(el('span','',source.report?`Обновлено ${new Date(source.report.fetchedAt).toLocaleString('ru-RU',{day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'})}`:'Ещё не загружена'));
  const actions=el('div','subscription-actions');
  if(source.remote){const refresh=el('button','icon-button');refresh.append(icon('refresh'));refresh.title='Обновить';refresh.setAttribute('aria-label','Обновить: '+source.name);refresh.onclick=()=>busy(refresh,async()=>{await api('subscription/refresh?id='+encodeURIComponent(source.id),'POST');await load();toast('Подписка обновлена');}).catch(e=>toast(e.message));actions.append(refresh);}
  if(group.owner){const edit=el('button','icon-button');edit.append(icon('info'));edit.title='Настройки подписки';edit.setAttribute('aria-label','Настройки: '+source.name);edit.onclick=()=>editSubscription(source);actions.append(edit);}
  row.append(info,actions);list.append(row);for(const warning of source.report?.warnings||[])warnings.push(source.name+': '+warning);
 });
 $('#subscription-warnings').textContent=warnings.join('\n');$('#subscription-warning-panel').hidden=!warnings.length;
 const filter=$('#source-filter'),selected=filter.value;filter.replaceChildren(new Option('Все подписки',''));sources.forEach(s=>filter.add(new Option(`${s.name} (${s.count})`,s.id)));filter.value=sources.some(s=>s.id===selected)?selected:'';
}
function editSubscription(source){
 const form=el('form');form.append(el('p','',source?'Измените название или укажите новую ссылку. Пустое поле ссылки сохранит текущую.':'Каждая подписка хранится отдельно. При загрузке используется общий профиль группы.'));
 const nameLabel=el('label','','Название'),name=el('input');name.maxLength=60;name.placeholder='Например, основная подписка';name.value=source?.name||'';name.required=!!source;nameLabel.append(name);
 const urlLabel=el('label','',source?'Новая HTTPS-ссылка (необязательно)':'HTTPS-ссылка'),url=el('input');url.type='url';url.required=!source;url.autocomplete='off';url.spellcheck=false;url.placeholder='https://example.com/sub/…';urlLabel.append(url);
 const error=el('p','form-error');error.setAttribute('role','alert');const save=el('button','primary',source?'Сохранить':'Добавить и загрузить');save.type='submit';form.append(nameLabel);if(!source||source.remote)form.append(urlLabel);form.append(error,save);
 let addedID='';form.onsubmit=async e=>{e.preventDefault();error.textContent='';try{await busy(save,async()=>{
  let id=source?.id||addedID;
  if(source||addedID)await api('subscriptions/'+encodeURIComponent(id),'PUT',{name:name.value.trim()||new URL(url.value).hostname,url:url.value.trim()});
  else {const result=await api('subscriptions','POST',{name:name.value.trim(),url:url.value.trim()});id=addedID=result.id;group=result.group;render();}
  if(!source||url.value.trim())await api('subscription/refresh?id='+encodeURIComponent(id),'POST');
  await load();$('#modal').close();toast('Подписка сохранена');
 });}catch(e){error.textContent=e.message;await load().catch(()=>{});}};
 if(source){const actions=el('div','dialog-actions');if(source.remote){const download=el('button','secondary','Скачать подписку');download.type='button';download.onclick=()=>busy(download,async()=>saveBlob(await api('subscription/export?id='+encodeURIComponent(source.id),'GET',undefined,true),'svoi-subscription.txt')).catch(e=>error.textContent=e.message);actions.append(download);}
  const remove=el('button','danger','Удалить источник');remove.type='button';remove.onclick=()=>{const c=el('div');c.append(el('p','',`Удалить «${source.name}» и ${source.count} серверов из списка? Активное соединение продолжит работать до отключения.`));const yes=el('button','danger','Удалить');yes.onclick=()=>busy(yes,async()=>{group=await api('subscriptions/'+encodeURIComponent(source.id),'DELETE');render();$('#modal').close();}).catch(e=>toast(e.message));const no=el('button','secondary','Назад');no.onclick=()=>editSubscription(source);const buttons=el('div','dialog-actions');buttons.append(no,yes);c.append(buttons);dialog('Удалить подписку?',c);};actions.append(remove);form.append(actions);
 }
 dialog(source?'Настройки подписки':'Добавить подписку',form);
}
async function showServerConfig(server){
 const content=el('div');content.append(el('p','','Загрузка конфигурации…'));dialog(server.name,content);
 const mode=$('#connection-mode').value,requestToken=token;
 try{const data=await api('servers/'+encodeURIComponent(server.id)+'/config?mode='+mode);if(!$('#modal').open||!content.isConnected||requestToken!==token)return;
  content.replaceChildren();const routing=el('div','routing-summary');routing.append(el('strong','',server.fullProfile?'Маршрутизация из профиля':'Один сервер · без правил провайдера'),el('p','',server.fullProfile?`В конфигурации для ${modeName(mode)}: правил — ${data.rules}, балансировщиков — ${data.balancers}. Сохраняются исходящие соединения и loopback-переходы. Входы адаптированы для SVOI; в TUN добавлена обработка DNS.`:'В ссылке сервера нет таблицы маршрутизации. Трафик отправляется через этот сервер; в TUN SVOI добавляет обработку DNS.'));content.append(routing);
  content.append(el('p','hint','Это конфигурация для следующего подключения, а не снимок запущенного ядра. Порты 10808/10809 показаны для примера; при запуске выбираются свободные. JSON содержит ключи доступа.'));
  const tabs=el('div','config-tabs');tabs.setAttribute('role','group');tabs.setAttribute('aria-label','Вариант конфигурации');const output=el('pre','log-output config-output');output.tabIndex=0;output.setAttribute('aria-label','JSON конфигурации');let current='effective';
  const effective=el('button','secondary','Для подключения'),original=el('button','secondary','Исходная');const fill=kind=>{current=kind;output.textContent=JSON.stringify(data[kind],null,2);effective.setAttribute('aria-pressed',String(kind==='effective'));original.setAttribute('aria-pressed',String(kind==='original'));};effective.onclick=()=>fill('effective');original.onclick=()=>fill('original');tabs.append(effective,original);
  const tools=el('div','log-toolbar'),copy=el('button','secondary','Копировать JSON'),download=el('button','secondary','Скачать JSON');copy.onclick=()=>clipboard(output.textContent);download.onclick=()=>saveBlob(new Blob([output.textContent],{type:'application/json'}),'svoi-'+current+'.json');tools.append(copy,download);content.append(tabs,output,tools);fill('effective');
 }catch(e){if(content.isConnected)content.replaceChildren(el('p','form-error',e.message));}
}
async function runProbes(servers){
 if(!connectionStatus?.available){toast(connectionStatus?.error||'Ядро Xray недоступно. Распакуйте полный архив приложения.');return;}
 if(probeRunning||!servers.length)return;probeRunning=true;const controller=new AbortController();probeAbort=controller;const gid=group.id,auth=token;let completed=0;const button=$('#probe-all');button.textContent='Остановить проверку';
 let next=0,frame=0;const paint=()=>{if(frame)return;frame=requestAnimationFrame(()=>{frame=0;if(group?.id===gid){renderServerLists();$('#probe-progress').textContent=`Проверено ${completed} из ${servers.length} · до 4 одновременно`;}});};
 const worker=async()=>{while(next<servers.length){if(controller.signal.aborted||group?.id!==gid||token!==auth)break;const server=servers[next++];
  const key=gid+':'+server.id;serverProbes.set(key,{busy:true});paint();
  try{const response=await fetch('/api/servers/'+encodeURIComponent(server.id)+'/probe',{method:'POST',headers:{Authorization:'Bearer '+auth},signal:controller.signal});const result=await response.json();if(!response.ok){const failure=Error(result.error||'Не удалось проверить');failure.status=response.status;throw failure;}serverProbes.set(key,result);}
  catch(e){if(e.name==='AbortError'){serverProbes.delete(key);break;}serverProbes.set(key,{error:e.message,label:e.status===502?'Нет ответа':e.status===503?'Нет ядра':e.status===429?'Занято':'Ошибка'});}completed++;paint();
 }};
 try{await Promise.all(Array.from({length:Math.min(4,servers.length)},worker));}finally{cancelAnimationFrame(frame);probeRunning=false;probeAbort=null;button.textContent='Проверить пинг';if(group?.id===gid){renderServerLists();$('#probe-progress').textContent=`${controller.signal.aborted?'Остановлено. ':''}Проверено ${completed} из ${servers.length}. HTTPS через профиль, включая его маршрутизацию. Активный VPN может влиять на результат.`;}}
}
$('#source-filter').onchange=renderServerLists;
$('#probe-all').onclick=()=>{if(probeRunning){probeAbort?.abort();return;}const source=$('#source-filter').value,search=$('#server-search').value.trim().toLocaleLowerCase();runProbes((group?.servers||[]).filter(s=>(!source||s.subscriptionId===source)&&`${s.name} ${s.address} ${s.protocol} ${countryLabel(s.name).code} ${countryLabel(s.name).country}`.toLocaleLowerCase().includes(search)));};
