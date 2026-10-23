const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {JSDOM}=require('jsdom');
const root=path.join(__dirname,'..');

async function fixture(){
 const dom=new JSDOM(fs.readFileSync(path.join(root,'web/index.html'),'utf8'),{url:'http://localhost/',runScripts:'outside-only',pretendToBeVisual:true});
 const w=dom.window,timers=new Map();let id=0;
 w.setTimeout=(fn,delay)=>{timers.set(++id,{fn,delay});return id;};w.clearTimeout=id=>timers.delete(id);
 w.scrollTo=()=>{};
 w.fetch=async()=>({ok:true,json:async()=>({available:true,state:'stopped',logs:[]})});
 const scripts=['app','countries','connection','library','transfer','settings'].map(name=>fs.readFileSync(path.join(root,'web',name+'.js'),'utf8')).join('\n');
 w.eval(scripts+`\nwindow.hooks={visiblePoll,refreshConnection,renderServerLists,renderConnectionPanel,renderZapret,view,welcome,init(count=1000){token='test';group={id:'g',name:'Test',owner:true,identity:{},devices:[],subscriptions:[{id:'sub',name:'Test source'}],servers:Array.from({length:count},(_,i)=>({id:String(i),name:'NL Server '+i,address:'example.com',port:443,protocol:'vless',subscriptionId:'sub'}))};connectionStatus={available:true,state:'stopped',logs:[]};},probe(id,value){serverProbes.set('g:'+id,value);},setRunning(){connectionStatus={available:true,state:'running',serverId:'0',logs:[],startedAt:new Date().toISOString()};},resetStatus(){connectionStatus={available:true,state:'stopped',logs:[]};}};`);
 await new Promise(resolve=>w.document.readyState==='loading'?w.document.addEventListener('DOMContentLoaded',resolve,{once:true}):resolve());
 timers.clear();
 return {dom,w,timers,h:w.hooks,close:()=>dom.window.close()};
}

test('large subscriptions are lazy; one ping result only replaces one row',async()=>{
 const f=await fixture();try{
  const {w,h}=f;h.init();h.renderServerLists();const list=w.document.querySelector('#all-servers');
  assert.equal(list.children.length,0,'hidden list must not be constructed');
  h.view('servers');assert.equal(list.children.length,1000);
  const rows=[...list.children],focus=rows[500].querySelector('input');focus.focus();
  const observer=new w.MutationObserver(()=>{});observer.observe(list,{childList:true,subtree:true});
  h.probe('0',{latency:42});h.renderServerLists();
  assert.equal(list.firstChild.querySelector('.latency-button').textContent,'42 мс');
  assert.equal(list.children[500],rows[500]);assert.equal(w.document.activeElement,focus);
  assert.equal([...list.children].filter((row,i)=>row!==rows[i]).length,1);
  assert.equal(observer.takeRecords().filter(r=>r.target===list).length,2,'only remove and insert the changed row');
  h.renderServerLists();assert.equal(observer.takeRecords().length,0,'stable rows must not mutate');
  w.document.querySelector('#server-search').value='Server 99';h.renderServerLists();
  assert.equal(list.children.length,11);assert.match(list.firstChild.textContent,/Server 99/);
  w.document.querySelector('#server-search').value='no matching server';h.renderServerLists();assert.equal(list.querySelectorAll('.server-row').length,0);
  w.document.querySelector('#server-search').value='';h.renderServerLists();assert.equal(list.children.length,1000);
  const radio=list.children[10].querySelector('input');radio.checked=true;radio.dispatchEvent(new w.Event('change'));
  assert.equal(list.querySelector('input:checked').value,'10');
  observer.disconnect();
 }finally{f.close();}
});

test('unchanged VPN polling does not rebuild the panel',async()=>{
 const f=await fixture();try{
  f.h.init(20);f.h.renderConnectionPanel();
  const hero=f.w.document.querySelector('.connection-hero'),observer=new f.w.MutationObserver(()=>{});observer.observe(hero,{childList:true,subtree:true,attributes:true});
  await f.h.refreshConnection();assert.equal(observer.takeRecords().length,0);observer.disconnect();
 }finally{f.close();}
});

test('visible poll pauses while hidden and never overlaps requests',async()=>{
 const f=await fixture();try{
  let hidden=false,calls=0,release;Object.defineProperty(f.w.document,'hidden',{get:()=>hidden,configurable:true});
  f.h.visiblePoll(()=>{calls++;return new Promise(resolve=>release=resolve);},()=>1234,()=>true);
  const [timerID,timer]=[...f.timers].find(([,t])=>t.delay===1234);assert.ok(timer);
  f.timers.delete(timerID);const pending=timer.fn();assert.equal(calls,1);
  f.w.document.dispatchEvent(new f.w.Event('visibilitychange'));assert.equal(calls,1);
  hidden=true;f.w.document.dispatchEvent(new f.w.Event('visibilitychange'));release();await pending;
  assert.equal(f.timers.size,0);
  hidden=false;f.w.document.dispatchEvent(new f.w.Event('visibilitychange'));assert.equal(calls,2);
  hidden=true;release();await new Promise(resolve=>setImmediate(resolve));
 }finally{f.close();}
});

test('zapret preview shows global counts and export fetches the complete report',async()=>{
 const f=await fixture();try{
  f.h.init(1);const summary={version:'test',logs:[],strategies:[],job:{kind:'standard',state:'done',resultCount:4000,successful:3000,results:Array.from({length:400},()=>({target:'example.com',check:'TLS',state:'ok',detail:'test'}))}};
  f.h.renderZapret(summary);
  assert.match(f.w.document.querySelector('#zapret-test-summary').textContent,/3000.*4000/);
  assert.equal(f.w.document.querySelector('#zapret-results').children.length,400);
  let requested='',blob;f.w.fetch=async url=>{requested=url;return {ok:true,json:async()=>({...summary,job:{...summary.job,results:Array(4000).fill(summary.job.results[0])}})}};
  f.w.URL.createObjectURL=value=>{blob=value;return 'blob:test';};f.w.URL.revokeObjectURL=()=>{};f.w.HTMLAnchorElement.prototype.click=()=>{};
  await f.w.document.querySelector('#zapret-export').onclick();assert.equal(requested,'/api/zapret');
  const text=await new Promise(resolve=>{const reader=new f.w.FileReader();reader.onload=()=>resolve(reader.result);reader.readAsText(blob);});
  assert.equal(JSON.parse(text).job.results.length,4000);
 }finally{f.close();}
});
