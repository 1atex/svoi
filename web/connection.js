'use strict';
let connectionStatus=null;
let selectedServer='';
let selectedGroup='';
let connectionBusy=false;
let connectionAction='';
let connectionActionError='';
let connectionPollBusy=false;
let connectionRevision=0;
let renderedConnectionKey='';
let modeTouched=false;
const serverSearchCache=new WeakMap();
const serverRowCache=new WeakMap();
function serverSearchText(server){
 let text=serverSearchCache.get(server);
 if(text===undefined){const country=countryLabel(server.name);text=`${server.name} ${server.address} ${server.protocol} ${country.code} ${country.country}`.toLocaleLowerCase();serverSearchCache.set(server,text);}
 return text;
}
try {const saved=localStorage.getItem('svoi.mode');if(['system','local','tun'].includes(saved))$('#connection-mode').value=saved;}catch{}
const modeName=mode=>({system:'Системный прокси',local:'Локальный прокси',tun:'TUN'})[mode]||'—';
function serverDetail(s){return s.fullProfile?`Узлов: ${s.nodeCount} · правила из подписки`:[`${s.address}:${s.port}`,s.network,s.security].filter(Boolean).join(' · ');}
function selectedConfig(){return group?.servers?.find(s=>s.id===selectedServer);}
function renderServerLists(){
 if(!group)return;
 const servers=group.servers||[];
 if(selectedGroup!==group.id){selectedGroup=group.id;selectedServer='';connectionActionError='';$('#all-servers').replaceChildren();serverRowCache.delete($('#all-servers'));}
 if(!servers.some(s=>s.id===selectedServer)){selectedServer=localStorage.getItem('svoi.server.'+group.id)||'';if(!servers.some(s=>s.id===selectedServer))selectedServer=servers[0]?.id||'';}
 $('#server-total').textContent=servers.length;

 $('#overview-servers').replaceChildren();
 if($('#servers').hidden)return;
 const search=$('#server-search').value.trim().toLocaleLowerCase();
 const source=$('#source-filter').value;
 const filtered=servers.filter(s=>(!source||s.subscriptionId===source)&&(!search||serverSearchText(s).includes(search)));
 renderServers($('#all-servers'),filtered);
 $('#server-results').textContent=(search||source)?`Найдено ${filtered.length} из ${servers.length}`:`Всего: ${servers.length}`;
}
function renderServers(root,servers){
 const focused=document.activeElement;const focusValue=root.contains(focused)&&focused?.type==='radio'?focused.value:null;
 const previous=serverRowCache.get(root);
 const cached=previous?.group===group.id?previous.rows:new Map();
 const rows=new Map(),nodes=[];
 const sources=new Map((group.subscriptions||[]).map(source=>[source.id,source.name]));
 serverRowCache.set(root,{group:group.id,rows});
 if(!servers.length){
  root.replaceChildren();
  const empty=el('div','empty-state');const badge=el('span','tile-icon');badge.append(icon('server'));
  const hasServers=!!group?.servers?.length;
  empty.append(badge,el('h3','',hasServers?'Сервер не найден':'Добавьте первый сервер'),el('p','',hasServers?'Попробуйте другое название, код страны или протокол.':'Вставьте ссылку подписки или импортируйте готовую конфигурацию.'));
  if(hasServers){const reset=el('button','secondary','Сбросить поиск');reset.onclick=()=>{$('#server-search').value='';$('#source-filter').value='';renderServerLists();$('#server-search').focus();};empty.append(reset);}
  else if(group?.owner){const add=el('button','secondary','Добавить подписку');add.onclick=subscriptionDialog;empty.append(add);}
  root.append(empty);return;
 }
 servers.forEach(s=>{
  const active=connectionStatus?.state==='running'&&connectionStatus.serverId===s.id;
  const sourceName=sources.get(s.subscriptionId)||'';
  const signature=[s,sourceName,active,!!connectionStatus?.checked,!!connectionStatus?.error,s.id===selectedServer,probeRunning,connectionStatus?.available,connectionStatus?.error,serverProbes.get(group.id+':'+s.id)];
  const old=cached.get(s.id);
  if(old&&signature.every((value,index)=>value===old.signature[index])){rows.set(s.id,old);nodes.push(old.node);return;}
  const row=el('div','server-row'+(s.id===selectedServer?' selected':''));const label=el('div','server-choice');const radio=el('input');
  radio.setAttribute('aria-label','Выбрать: '+s.name);radio.type='radio';radio.name=root.id+'-selected';radio.value=s.id;radio.checked=s.id===selectedServer;
  radio.onchange=()=>{selectedServer=s.id;localStorage.setItem('svoi.server.'+group.id,s.id);renderServerLists();renderConnectionPanel();};
  const info=el('span','server-info');const name=el('button','server-name server-open');name.type='button';name.title='Открыть конфигурацию';name.onclick=()=>showServerConfig(s);renderCountryTitle(name,s.name);info.append(name,el('span','server-address',serverDetail(s)),el('span','server-source',sourceName));const selector=el('label','server-selector');selector.title='Выбрать сервер';selector.append(radio);label.append(selector,info);
  row.append(label,el('span','pill'+(active&&connectionStatus.checked&&!connectionStatus.error?' green':''),active?'Активный':s.fullProfile?'Профиль':s.protocol.toUpperCase()));
  const exportButton=el('button','icon-button');exportButton.title='Экспорт конфигурации';exportButton.setAttribute('aria-label','Экспорт Xray: '+s.name);exportButton.append(icon('download'));
  exportButton.onclick=()=>busy(exportButton,async()=>{const blob=await api('servers/'+encodeURIComponent(s.id)+'/export','GET',undefined,true);saveBlob(blob,'svoi-xray.json');}).catch(e=>toast(e.message));
  const actions=el('div','server-actions');const ping=el('button','latency-button');const result=serverProbes.get(group.id+':'+s.id);ping.textContent=result?.busy?'Проверка…':result?.error?(result.label||'Ошибка'):result?result.latency+' мс':'Пинг';ping.classList.toggle('failed',!!result?.error);ping.title=result?.error||'HTTPS-проверка через этот профиль';ping.setAttribute('aria-label','Проверить пинг: '+s.name);ping.disabled=probeRunning||!connectionStatus?.available;if(!connectionStatus?.available){ping.textContent=connectionStatus?'Недоступно':'…';ping.title=connectionStatus?.error||'Проверяем ядро Xray…';}ping.onclick=()=>runProbes([s]);actions.append(ping);if(result?.error){const why=el('button','icon-button');why.append(icon('info'));why.setAttribute('aria-label','Причина ошибки: '+s.name);why.onclick=()=>{const detail=el('div');detail.append(el('p','form-error',result.error));dialog('Проверка: '+s.name,detail);};actions.append(why);}actions.append(exportButton);row.append(actions);
  rows.set(s.id,{signature,node:row});nodes.push(row);
 });

 const retained=new Set(nodes);
 for(const node of [...root.childNodes])if(!retained.has(node))node.remove();
 let cursor=root.firstChild;
 for(const node of nodes){if(node===cursor)cursor=cursor.nextSibling;else root.insertBefore(node,cursor);}
 while(cursor){const next=cursor.nextSibling;cursor.remove();cursor=next;}
 if(focusValue){const input=$$('input',root).find(n=>n.value===focusValue);input?.focus({preventScroll:true});}
}
function saveBlob(blob,name){const url=URL.createObjectURL(blob);const a=el('a');a.href=url;a.download=name;document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);}
function updateUptime(){
 const started=Date.parse(connectionStatus?.startedAt||'');const running=connectionStatus?.state==='running';
 const secs=Math.max(0,Math.floor((Date.now()-started)/1000));
 const value=running&&Number.isFinite(secs)?`${String(Math.floor(secs/3600)).padStart(2,'0')}:${String(Math.floor(secs/60)%60).padStart(2,'0')}:${String(secs%60).padStart(2,'0')}`:'—';
 if($('#metric-uptime').textContent!==value)$('#metric-uptime').textContent=value;
}
function renderConnectionPanel(){
 if(!group)return;
 const s=selectedConfig(),c=connectionStatus,running=c?.state==='running',mode=$('#connection-mode').value;
 const same=running&&c.serverId===selectedServer&&c.mode===mode;
 const error=connectionActionError||c?.error||'';
 const unavailable=c!==null&&!c?.available;
 const verified=running&&c.checked&&!error;
 renderCountryTitle($('#selected-server-name'),s?.name||'Выбрать сервер');
 $('#connection-detail').textContent=s?serverDetail(s):'Добавьте подписку или конфигурацию';
 const state=$('#connection-state');
 state.textContent=connectionBusy?({start:'Подключение…',stop:'Отключение…',check:'Проверка…'})[connectionAction]||'Подождите…':verified?'Связь проверена':running?(error?'Сбой проверки':'Проверка не выполнена'):error?'Ошибка':'Отключено';
 state.classList.toggle('green',verified&&!connectionBusy);state.classList.toggle('error',!!error&&!connectionBusy);
 const hero=$('.connection-hero');hero.classList.toggle('is-running',verified);hero.dataset.state=connectionBusy?'busy':error?'error':running?'running':'stopped';
 $('#connection-headline').textContent=connectionBusy?({start:'Подключаемся',stop:'Отключаемся',check:'Проверяем соединение'})[connectionAction]:running?(error?'Проверьте соединение':verified?'VPN подключён':'Соединение запущено'):!s?'Начните с подписки':error?'Не удалось подключиться':'Готов к подключению';
 $('#connection-caption').textContent=running&&!same?`Сейчас: ${c.serverName}`:running?(error?'Ядро работает, но проверка связи не прошла.':verified?'Проверочный запрос прошёл через VPN.':'Ядро запущено. Проверьте доступ к сети.'):!s?'Добавьте сервер, чтобы выйти в сеть.':'Выберите режим и нажмите «Подключить».';
 const connect=$('#connect-button');connect.disabled=connectionBusy||!s||!c?.available;
 connect.replaceChildren(icon(connectionBusy?'refresh':'power'),document.createTextNode(connectionBusy?state.textContent:unavailable?'Ядро недоступно':same?'Отключить':running?'Подключить выбранный':'Подключить'));
 connect.setAttribute('aria-busy',String(connectionBusy));
 $('#disconnect-button').hidden=!running||same;$('#disconnect-button').disabled=connectionBusy;
 $('#check-connection').disabled=!running||connectionBusy;$('#connection-mode').disabled=connectionBusy;
 $('#core-state').textContent=c===null?'Проверка…':c.available?'Готово':'Недоступно';$('#core-state').classList.toggle('green',!!c?.available);
 $('#core-version').textContent=c?.version?.match(/^Xray\s+\S+/)?.[0]||'Xray Core';$('#core-version').title=c?.version||'';
 $('#core-endpoints').textContent=running?`SOCKS5  127.0.0.1:${c.socksPort}\nHTTP      127.0.0.1:${c.httpPort}`:c===null?'Проверяем ядро Xray…':c.available?'Ядро готово. Запустите VPN для проверки связи.':'Ядро недоступно. Проверьте наличие core/xray.exe рядом с приложением.';
 $('#connection-feedback').hidden=!error;$('#connection-error').textContent=error;
 $('#connection-error-title').textContent=running?'Проверка связи не прошла':'Не удалось выполнить действие';
 $('#connection-error-help').textContent=/администратор|administrator|access.*denied|отказано/i.test(error)?'Для режима TUN запустите SVOI от имени администратора.':running?'Повторите проверку или выберите другой сервер. Подробности доступны в журнале.':'Проверьте выбранный сервер и откройте журнал, если ошибка повторяется.';
 if(unavailable){$('#connection-headline').textContent=c?.problem==='core_missing'?'Не найдено ядро Xray':'Ядро Xray недоступно';$('#connection-caption').textContent='Установите приложение вместе с ядром через установщик SVOI.';$('#connection-feedback').hidden=false;$('#connection-error-title').textContent='Подключение и пинг пока недоступны';$('#connection-error-help').textContent='Запустите установщик SVOI или распакуйте весь Windows-архив с папкой core. Затем перезапустите приложение. Ваши профили сохранятся.';}
 $('#probe-all').disabled=unavailable&&!probeRunning;
 if(unavailable&&!probeRunning)$('#probe-progress').textContent=c?.error||'Проверка недоступна: ядро Xray не готово.';
 $('#mode-description').textContent=mode==='system'?'Для браузеров и приложений с поддержкой системного прокси.':mode==='local'?'Укажите локальный порт вручную в нужном приложении.':'Перехват IP-трафика с правилами раздела «Приложения». Нужны права администратора.';
 $('#connection-note').textContent=running?`Подключён: ${c.serverName}. ${modeName(c.mode)}.${!same?' Выбор другого сервера или режима применится после нажатия кнопки подключения.':''}`:'После отключения SVOI восстанавливает прежние настройки системного прокси.';
 $('#metric-mode').textContent=running?modeName(c.mode):'—';$('#metric-latency').textContent=verified?`${c.latency} мс`:running?(error?'Ошибка':'Не проверено'):'—';updateUptime();
 const header=$('#header-status');header.classList.toggle('connected',verified);header.classList.toggle('failed',!!error);$('span',header).textContent=connectionBusy?'Подождите…':running?(verified?'VPN подключён':'VPN · проверьте связь'):'VPN отключён';
 $('#connection-note').closest('.note').hidden=!running;
 const key=`${c?.available}:${c?.problem}:${c?.state}:${c?.serverId}:${c?.checked}:${!!c?.error}`;if(key!==renderedConnectionKey){renderedConnectionKey=key;renderServerLists();}
 document.dispatchEvent(new Event('svoi:state'));
}
async function refreshConnection(){
 if(!group||connectionPollBusy||connectionBusy)return;connectionPollBusy=true;const session=token;const revision=connectionRevision;
 try{const result=await api('connection');if(session===token&&revision===connectionRevision&&!connectionBusy){if(connectionStatus===null&&result.state==='running'&&!modeTouched)$('#connection-mode').value=result.mode;const changed=JSON.stringify({...connectionStatus,logs:null})!==JSON.stringify({...result,logs:null});connectionStatus=result;if(changed)renderConnectionPanel();}}
 catch(e){if(session===token&&revision===connectionRevision&&!connectionBusy){connectionStatus={available:false,state:'stopped',error:e.message,logs:[]};renderConnectionPanel();}}
 finally{connectionPollBusy=false;}
}
async function changeConnection(action){
 if(connectionBusy)return;connectionRevision++;connectionBusy=true;connectionAction=action;connectionActionError='';renderConnectionPanel();
 try{
  const payload=action==='start'?{serverId:selectedServer,mode:$('#connection-mode').value}:undefined;
  connectionStatus=await api('connection/'+action,'POST',payload);
  if(action==='start'){connectionAction='check';renderConnectionPanel();connectionStatus=await api('connection/check','POST');}
  if(action==='stop')toast('VPN отключён');else if(connectionStatus.checked)toast('Проверка связи пройдена');
 }catch(e){connectionActionError=e.message;}
 finally{connectionBusy=false;connectionAction='';await refreshConnection();renderConnectionPanel();}
}
$('#connect-button').onclick=()=>{const same=connectionStatus?.state==='running'&&connectionStatus.serverId===selectedServer&&connectionStatus.mode===$('#connection-mode').value;changeConnection(same?'stop':'start');};
$('#disconnect-button').onclick=()=>changeConnection('stop');
$('#check-connection').onclick=()=>changeConnection('check');
$('#connection-mode').onchange=()=>{modeTouched=true;localStorage.setItem('svoi.mode',$('#connection-mode').value);renderConnectionPanel();};
let searchTimer;$('#server-search').oninput=()=>{clearTimeout(searchTimer);searchTimer=setTimeout(renderServerLists,120);};
$('#show-logs').onclick=()=>{
 const content=el('div');const output=el('pre','log-output');const toolbar=el('div','log-toolbar');
 const fill=async()=>{try{const status=await api('connection?logs=1');output.textContent=(status.logs||[]).join('\n')||'Журнал пока пуст.';}catch(e){output.textContent=e.message;}};fill();
 const refresh=el('button','secondary','Обновить');refresh.prepend(icon('refresh'));refresh.onclick=()=>busy(refresh,async()=>{await fill();});
 const copy=el('button','secondary','Скопировать');copy.prepend(icon('copy'));copy.onclick=()=>clipboard(output.textContent);
 toolbar.append(refresh,copy);content.append(el('p','','Последние сообщения ядра. Пароли и ID скрываются.'),toolbar,output);dialog('Журнал Xray',content);
};
visiblePoll(updateUptime,()=>1000,()=>!!group&&!$('#overview').hidden&&connectionStatus?.state==='running');
function importConfigDialog(){const form=el('form');form.append(el('p','','Вставьте VLESS, VMess, Trojan, Shadowsocks, Base64-подписку или Xray JSON. Импорт добавит отдельный источник, сохранив остальные подписки.'));const label=el('label','','Конфигурация');const text=el('textarea');text.required=true;text.spellcheck=false;text.placeholder='vless://…';label.append(text);const fileLabel=el('label','','Или выберите файл');const file=el('input');file.type='file';file.accept='.json,.txt,.conf';fileLabel.append(file);const err=el('p','form-error');err.setAttribute('role','alert');file.onchange=async()=>{const f=file.files[0];if(!f)return;if(f.size>4*1024*1024){err.textContent='Максимальный размер — 4 МБ';return;}text.value=await f.text();};const b=el('button','primary','Импортировать серверы');b.type='submit';form.append(label,fileLabel,err,b);form.onsubmit=async event=>{event.preventDefault();err.textContent='';try{await busy(b,async()=>{group=await api('subscription/import','POST',{content:text.value});render();$('#modal').close();toast(`Добавлен источник: ${group.subscriptions?.at(-1)?.count||0} серверов`);});}catch(e){err.textContent=e.message;}};dialog('Импорт конфигурации',form);}
$$('.import-config-button').forEach(b=>b.onclick=importConfigDialog);
visiblePoll(refreshConnection,()=>connectionStatus?.state==='running'?2500:10000,()=>!!group);
if(group){renderServerLists();renderConnectionPanel();refreshConnection();}
