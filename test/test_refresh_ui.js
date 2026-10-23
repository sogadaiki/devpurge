// Deterministic UI state/timer regression checks; no browser or real Mac probes.
'use strict';
const assert=require('node:assert/strict'), vm=require('node:vm'), fs=require('node:fs'), path=require('node:path');
const buttons=[{}, {}, {}], timers=new Map();let serial=0, checks=0;
const context=vm.createContext({
  window:{}, document:{addEventListener(){},querySelectorAll(){return buttons;}},
  busy:false, state:{progress:{running:false}},
  setTimeout(fn,delay){assert.equal(delay,300000);timers.set(++serial,fn);return serial;},
  clearTimeout(id){timers.delete(id);}, act:async fn=>fn(),
});
vm.runInContext(fs.readFileSync(path.join(__dirname,'../ui/refresh.js'),'utf8'),context);
(async()=>{
  context.busy=true;vm.runInContext('updateRefreshBusy()',context);
  assert.ok(buttons.every(b=>b.disabled));
  context.busy=false;vm.runInContext('updateRefreshBusy()',context);
  assert.ok(buttons.every(b=>!b.disabled),'buttons must recover after a cancelled native confirmation');
  context.state.progress.running=true;vm.runInContext('updateRefreshBusy()',context);
  assert.ok(buttons.every(b=>b.disabled));context.state.progress.running=false;
  context.checkPressure=async quiet=>{assert.equal(quiet,true);checks++;};
  vm.runInContext('pressureWatching=true;schedulePressure()',context);
  const tick=async()=>{const [id,fn]=timers.entries().next().value;timers.delete(id);await fn();};
  await tick();assert.equal(checks,1);assert.equal(timers.size,1);
  context.busy=true;await tick();assert.equal(checks,1,'active work must skip sampling');context.busy=false;
  vm.runInContext('pressureWatching=false;schedulePressure()',context);assert.equal(timers.size,0);
  context.state.pressure={system:{process_tree:[{pid:1,parent:0,footprint:10},{pid:2,parent:1,footprint:20},{pid:3,parent:2,footprint:null},{pid:4,parent:0,footprint:999}]}};
  assert.equal(vm.runInContext('appMemory({pid:1}).bytes',context),30);
  assert.equal(vm.runInContext('appMemory({pid:1}).partial',context),true);
  assert.equal(vm.runInContext('appMemory({pid:5}).bytes',context),null);
  console.log('Refresh UI: busy recovery, bounded timer, skipped work and memory grouping passed');
})().catch(error=>{console.error(error);process.exitCode=1;});
