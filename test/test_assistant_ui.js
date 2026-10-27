'use strict';
// Confirmation remains human-only; expired tickets cannot be submitted by UI.
const assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const source=fs.readFileSync(require('node:path').join(__dirname,'../ui/assistant.js'),'utf8');
const elements={};for(const key of ['.close','#assistant-execute','#assistant-cancel','.assistant-live'])elements[key]={disabled:false};
let calls=0,now=1000000;const timers=new Map();let serial=0;
const dialog={open:false,querySelector:s=>elements[s],querySelectorAll:()=>Object.values(elements),showModal(){this.open=true;},close(){this.open=false;}};
const context=vm.createContext({assistantDialog:dialog,assistantExpiryTimer:null,esc:String,bytes:String,assistantDetails:()=>'',
 $:s=>elements[s],Date:{now:()=>now},setTimeout(fn){timers.set(++serial,fn);return serial;},clearTimeout(id){timers.delete(id);},
 api:async()=>{calls++;throw new Error('verification changed');},loadAssistant:async()=>{},act:async fn=>{try{await fn();}catch{}},
});
vm.runInContext(source.slice(source.indexOf('function showAssistantPlan('),source.lastIndexOf('assistantNav.click();')),context);
context.plan={id:'fixture',at:1000,bytes:123,entries:[{id:'one'}]};
vm.runInContext('showAssistantPlan(plan)',context);
assert.equal(calls,0);assert.equal(dialog.open,true);assert.equal(elements['#assistant-execute'].disabled,false);
assert.match(elements['.assistant-live'].textContent,/5分0秒/);
now+=301000;const tick=timers.values().next().value;timers.clear();tick();
assert.equal(elements['#assistant-execute'].disabled,true);assert.match(elements['.assistant-live'].textContent,/期限が切れ/);
elements['#assistant-cancel'].onclick();assert.equal(dialog.open,false);assert.equal(calls,0);
(async()=>{now=1000000;vm.runInContext('showAssistantPlan(plan)',context);await elements['#assistant-execute'].onclick();assert.equal(calls,1);assert.equal(elements['#assistant-execute'].disabled,true,'failed/consumed ticket must not be retried');assert.equal(elements['#assistant-cancel'].disabled,false);console.log('Assistant UI: manual confirmation, expiry and failed-ticket recovery passed');})().catch(e=>{console.error(e);process.exitCode=1;});
