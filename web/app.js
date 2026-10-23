'use strict';
const $ = (s, root=document) => root.querySelector(s);
const $$ = (s, root=document) => [...root.querySelectorAll(s)];
const paths = {
 settings:'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8 M12 2v3 M12 19v3 M2 12h3 M19 12h3 M5 5l2 2 M17 17l2 2 M5 19l2-2 M17 7l2-2',
 grid:'M3 3h7v7H3z M14 3h7v7h-7z M3 14h7v7H3z M14 14h7v7h-7z',
 server:'M3 3h18v7H3z M3 14h18v7H3z M7 6.5h.1 M7 17.5h.1 M11 6.5h6 M11 17.5h6',logs:'M5 3h14v18H5z M8 7h8 M8 11h8 M8 15h5',
 devices:'M3 4h15v11H3z M7 20h7 M10.5 15v5 M18 9h4v12h-7v-3',
 fingerprint:'M5 12a7 7 0 0 1 14 0 M8 13v-1a4 4 0 0 1 8 0v3c0 3-1 5-2 7 M11 12v5c0 2-1 4-2 5 M5 16c0 2-1 4-2 5 M3 8a10 10 0 0 1 18 0 M19 16c0 2 0 3-1 5',
 arrow:'M5 12h14 M13 6l6 6-6 6', plus:'M12 5v14 M5 12h14',
 link:'M10 13a5 5 0 0 0 7 0l3-3a5 5 0 0 0-7-7l-2 2 M14 11a5 5 0 0 0-7 0l-3 3a5 5 0 0 0 7 7l2-2',
 shield:'M12 2l8 4v6c0 5-8 10-8 10S4 17 4 12V6z M8 12l3 3 5-6',
 copy:'M8 8h13v13H8z M16 5V3H3v13h2', refresh:'M20 7v5h-5 M4 17v-5h5 M6 6a8 8 0 0 1 14 6 M18 18a8 8 0 0 1-14-6',
 download:'M12 3v12 M7 10l5 5 5-5 M4 16v5h16v-5', power:'M12 2v10 M6 5a9 9 0 1 0 12 0',
 info:'M12 11v6 M12 7v.1 M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0', close:'M6 6l12 12 M18 6L6 18',
 desktop:'M2 3h20v14H2z M8 21h8 M12 17v4',phone:'M7 2h10v20H7z M10 5h4 M11 19h2',trash:'M3 6h18 M9 6V3h6v3 M6 6l1 15h10l1-15 M10 10v7 M14 10v7'
};
function icon(name) { const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('viewBox','0 0 24 24');svg.setAttribute('aria-hidden','true');const p=document.createElementNS(svg.namespaceURI,'path');p.setAttribute('d',paths[name]||paths.devices);svg.append(p);return svg; }
function icons(root=document) {$$('[data-icon]',root).forEach(el=>el.replaceChildren(icon(el.dataset.icon)));}
function el(tag, cls, text) {const n=document.createElement(tag);if(cls)n.className=cls;if(text!==undefined)n.textContent=text;return n;}
function pluralRU(n,one,few,many){const x=Math.abs(n)%100;return x>10&&x<20?many:x%10===1?one:x%10>=2&&x%10<=4?few:many;}
let sessions=[];let token='';let group=null;let toastTimer;
try {sessions=JSON.parse(localStorage.getItem('svoi.sessions')||'[]');if(!Array.isArray(sessions))sessions=[];token=localStorage.getItem('svoi.active')||'';}catch{sessions=[];}
function remember(){localStorage.setItem('svoi.sessions',JSON.stringify(sessions));localStorage.setItem('svoi.active',token);}
function toast(message){$('#toast').textContent=message;$('#toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('#toast').hidden=true,5000);}
async function api(path, method='GET', body, download=false) {
 const options={method,headers:{'Authorization':`Bearer ${token}`}};
 if(body!==undefined){options.headers['Content-Type']='application/json';options.body=JSON.stringify(body);}
 let response;try{response=await fetch('/api/'+path,options);}catch{throw Error('Сервис недоступен. Убедитесь, что SVOI запущен.');}
 if(!response.ok){let message='Не удалось выполнить запрос';try{message=(await response.json()).error||message;}catch{}if(response.status===401){sessions=sessions.filter(s=>s.token!==token);token='';remember();welcome();}throw Error(message);}
 return download?response.blob():response.json();
}
function detectPlatform(){const p=navigator.userAgent;if(/Android/i.test(p))return 'Android';if(/iPhone|iPad/i.test(p))return 'iOS';if(/Macintosh/i.test(p))return 'macOS';if(/Windows/i.test(p))return 'Windows';return 'Linux';}
function view(name){if(!group){welcome();return;}$$('.view').forEach(v=>v.hidden=v.id!==name);$$('.nav').forEach(b=>{b.classList.toggle('active',b.dataset.view===name);if(b.dataset.view===name)b.setAttribute('aria-current','page');else b.removeAttribute('aria-current');});window.scrollTo({top:0,behavior:'instant'});$('#breadcrumb').textContent=({overview:'Подключение',servers:'Серверы',devices:'Перенос профиля',identity:'Параметры запроса',settings:'Настройки',applications:'Приложения',zapret:'zapret'})[name];if(typeof viewExtras==='function')viewExtras(name);}
function welcome(){group=null;$('#workspace').hidden=true;$('#welcome').hidden=false;$('#breadcrumb').textContent='Начало';$('#group-title').textContent='SVOI';$('#nav-count').textContent='0';const saved=$('#saved-sessions');saved.replaceChildren();sessions.forEach(s=>{const b=el('button','secondary saved-session',`Вернуться: ${s.name}`);b.onclick=()=>busy(b,async()=>{token=s.token;remember();await load();}).catch(e=>toast(e.message));saved.append(b);});}
async function load(){group=await api('me');render();if(typeof refreshConnection==='function')await refreshConnection();if(typeof onGroupReady==='function')onGroupReady();}
function render(){
 $('#welcome').hidden=true;$('#workspace').hidden=false;$('#group-title').textContent=group.name;$('#hero-hwid').textContent=group.identity.hwid;
 $('#nav-count').textContent=group.devices.length;$('#device-total').textContent=group.devices.length;
 const self=group.devices.find(d=>d.id===group.self);$('#switch-session').textContent=self?.name?.slice(0,1).toUpperCase()||'S';
 $$('.invite-button').forEach(b=>b.hidden=!group.owner);$('#leave-group').hidden=group.owner;
 for(const name of ['hwid','os','model','locale','userAgent']){const input=$(`[name="${name}"]`,$('#identity-form'));input.value=group.identity[name];input.disabled=!group.owner;}
 $('#identity-form button[type="submit"]').hidden=!group.owner;
 renderDevices($('#overview-devices'),group.devices.slice(0,3));renderDevices($('#all-devices'),group.devices);
 $$('.import-config-button').forEach(b=>b.hidden=!group.owner);
 renderSubscriptions();
 if(typeof renderServerLists==='function'){renderServerLists();renderConnectionPanel();}
 view($$('.view').find(v=>!v.hidden)?.id||'overview');
}
function renderDevices(root,list){root.replaceChildren();list.forEach(d=>{
 const row=el('div','device-row');const di=el('span','device-icon');di.append(icon(/Android|iOS/.test(d.platform)?'phone':'desktop'));
 const info=el('div','device-info');const name=el('div','device-name',d.name);if(d.id===group.self)name.append(el('span','pill','Это устройство'));
 info.append(name,el('div','device-platform',`${d.platform} · ${d.owner?'Владелец':'Участник'}`));row.append(di,info);
 row.append(el('span','device-meta',`Добавлено ${new Date(d.joined).toLocaleDateString('ru-RU')}`));
 if(group.owner&&!d.owner){const b=el('button','icon-button');b.setAttribute('aria-label',`Отозвать доступ: ${d.name}`);b.append(icon('trash'));b.onclick=()=>confirmRevoke(d);row.append(b);}else row.append(el('span','pill',d.owner?'Владелец':'Участник'));root.append(row);
 });}
async function busy(button,fn){button.disabled=true;button.setAttribute('aria-busy','true');try{return await fn();}finally{button.disabled=false;button.removeAttribute('aria-busy');}}
function formHandler(selector,fn){const form=$(selector);form.addEventListener('submit',async e=>{e.preventDefault();const error=$('.form-error',form);error.textContent='';try{await busy($('[type="submit"]',form),()=>fn(Object.fromEntries(new FormData(form)),form));}catch(e){error.textContent=e.message;}});}
function acceptSession(result){token=result.token;group=result.group;sessions.push({token,name:group.name+' / '+group.devices.find(d=>d.id===group.self).name});remember();render();view('overview');if(typeof refreshConnection==='function')refreshConnection();if(typeof onGroupReady==='function')onGroupReady();}
function dialog(title,content){$('#dialog-title').textContent=title;$('#dialog-content').replaceChildren(content);if(!$('#modal').open)$('#modal').showModal();}
async function clipboard(value){try{await navigator.clipboard.writeText(value);toast('Скопировано');}catch{toast('Не удалось скопировать. Выделите и скопируйте текст вручную.');}}
function invite(){shareProfile();}
function subscriptionDialog(){editSubscription();}
function confirmRevoke(device){const content=el('div');content.append(el('p','',`Устройство «${device.name}» потеряет доступ к группе. Скачанные ранее конфигурации останутся на нём.`));const actions=el('div','dialog-actions');const cancel=el('button','secondary','Отмена');cancel.onclick=()=>$('#modal').close();const yes=el('button','danger','Отозвать доступ');yes.onclick=()=>busy(yes,async()=>{group=await api('devices/'+encodeURIComponent(device.id),'DELETE');render();$('#modal').close();toast('Доступ отозван');}).catch(e=>toast(e.message));actions.append(cancel,yes);content.append(actions);dialog('Отозвать доступ?',content);}
$$('[data-view]').forEach(b=>{b.onclick=()=>view(b.dataset.view);if(b.classList.contains('nav'))b.title=({overview:'Подключение',servers:'Серверы',devices:'Перенос профиля',identity:'Параметры запроса',settings:'Настройки',applications:'Приложения',zapret:'zapret'})[b.dataset.view];});$$('.invite-button').forEach(b=>b.onclick=invite);
$('#close-dialog').onclick=()=>$('#modal').close();$('#copy-hwid').onclick=()=>clipboard(group.identity.hwid);
$('#switch-session').onclick=welcome;$('#add-subscription').onclick=subscriptionDialog;
$('#refresh-subscription').onclick=()=>busy($('#refresh-subscription'),async()=>{const report=await api('subscription/refresh','POST');await load();toast(`Загружено серверов: ${report.count}`);}).catch(e=>toast(e.message));
$('#download-subscription').onclick=()=>busy($('#download-subscription'),async()=>{const blob=await api('subscription/export','GET',undefined,true);const url=URL.createObjectURL(blob);const a=el('a');a.href=url;a.download='svoi-subscription.txt';document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);await load();toast('Конфигурация скачана');}).catch(e=>toast(e.message));
$('#leave-group').onclick=()=>{const content=el('div');content.append(el('p','','Чтобы вернуться, понадобится новый инвайт от владельца.'));const b=el('button','danger','Покинуть группу');b.onclick=()=>busy(b,async()=>{await api('leave','POST');sessions=sessions.filter(s=>s.token!==token);token='';remember();$('#modal').close();welcome();toast('Вы покинули группу');}).catch(e=>toast(e.message));content.append(b);dialog('Покинуть группу?',content);};
formHandler('#create-form',async data=>acceptSession(await api('groups','POST',data)));
formHandler('#join-form',async data=>previewTransfer(data));
formHandler('#identity-form',async identity=>{group=await api('identity','PUT',{identity});render();toast('Общий профиль сохранён');});
$$('input[name="platform"]').forEach(i=>i.value=detectPlatform());icons();
document.addEventListener('DOMContentLoaded',()=>{if(token){load().catch(e=>{welcome();toast(e.message);});}else welcome();});
