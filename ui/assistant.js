'use strict';
const assistantStyles=document.createElement('link');assistantStyles.rel='stylesheet';assistantStyles.href='/assistant.css';document.head.append(assistantStyles);
const assistantNav=document.createElement('button');
assistantNav.textContent='✧ AIで片付ける';assistantNav.dataset.view='assistant';
document.querySelector('nav').prepend(assistantNav);
const assistantAdvanced=document.createElement('details');assistantAdvanced.className='assistant-advanced';assistantAdvanced.innerHTML='<summary>詳しいツール</summary>';
document.querySelectorAll('nav button').forEach(b=>{if(!['assistant','overview','history'].includes(b.dataset.view))assistantAdvanced.append(b);});document.querySelector('nav').append(assistantAdvanced);
const assistantSection=document.createElement('section');
assistantSection.id='assistant';assistantSection.className='view';assistantSection.hidden=true;
document.querySelector('main').insertBefore(assistantSection,document.querySelector('.main-footer'));
const assistantDialog=document.createElement('dialog');document.body.append(assistantDialog);
let assistantTimer,assistantAwaitingReview=false,assistantWorking=false,assistantStarted=0,assistantExpiryTimer;
function assistantDetails(rows){return rows.map(x=>`<details class="assistant-item"><summary><span>${esc(x.title)}</span><strong>${bytes(x.bytes)}</strong></summary>${x.original?`<p class="wrap">元の場所：${esc(x.original)}</p>`:''}<p class="wrap">対象：${esc(x.path)}</p><p>${esc(x.reason)}</p>${x.ai_reason?`<p class="muted">AI：${esc(x.ai_reason)}</p>`:''}</details>`).join('');}
function paintAssistantActivity(data){
 const p=data.progress||{},op=data.operation||{},running=assistantWorking||op.running||p.running;
 const area=$('#assistant-activity');if(!area)return;area.hidden=!running;
 $('#assistant-activity-text').textContent=p.message||'調査を始めています';
 const meter=$('#assistant-meter');if(p.total>0){meter.max=p.total;meter.value=Math.min(p.done||0,p.total);}else meter.removeAttribute('value');
 const elapsed=Math.max(0,Math.floor((Date.now()-(assistantStarted||op.at*1000||Date.now()))/1000));
 $('#assistant-count').textContent=`${p.total>0?`${p.done||0} / ${p.total}件 · `:''}${Math.floor(elapsed/60)}分${elapsed%60}秒`;
}
async function watchAssistant(){
 clearTimeout(assistantTimer);
 try{const data=await api('assistant-progress');paintAssistantActivity(data);
  if(assistantWorking||data.operation.running||data.progress.running){assistantTimer=setTimeout(watchAssistant,1000);return;}
  await loadAssistant();
 }catch(e){notice('進行状況を取得できません。処理を重ねず、接続の回復を待っています。',true);assistantTimer=setTimeout(watchAssistant,3000);}
}
async function requestAssistantPlan(ids){
 if(assistantWorking)return;assistantWorking=true;assistantStarted=Date.now();
 assistantSection.querySelectorAll('button').forEach(b=>b.disabled=true);
 paintAssistantActivity({progress:{message:'削除候補と保持元を再確認しています'}});watchAssistant();
 try{showAssistantPlan(await api('assistant',{action:'plan',ids}));}
 finally{assistantWorking=false;clearTimeout(assistantTimer);await loadAssistant();}
}
function quarantineHTML(items,busy=false){
 const groups=Object.groupBy?Object.groupBy(items,x=>x.project||'その他'):items.reduce((a,x)=>{(a[x.project||'その他']??=[]).push(x);return a;},Object.create(null));
 return `<details class="panel"><summary>隔離中のデータ（${items.length}件）</summary><p>隔離しただけでは空き容量は増えません。期限だけでは削除せず、「AIで片付ける」で保持元を再検証します。</p>${Object.entries(groups).map(([name,rows])=>`<h3>${esc(name)} · ${bytes(rows.reduce((n,x)=>n+x.bytes,0))}</h3>${rows.map(x=>`<div class="detail-block"><strong>${esc(x.title)} · ${bytes(x.bytes)}</strong><p class="path">元の場所：${esc(x.original)}</p><p>隔離日 ${new Date(x.epoch*1000).toLocaleDateString('ja-JP')} ／ 再確認の目安 ${new Date(x.review_after*1000).toLocaleDateString('ja-JP')}</p><button data-q-restore="${esc(x.id)}" ${busy?'disabled':''}>元の場所へ復元</button> <button data-q-hold="${esc(x.id)}" ${busy?'disabled':''}>30日保持を延長</button></div>`).join('')}`).join('')}</details>`;
}
function bindQuarantine(container,refresh){
 container.querySelectorAll('[data-q-restore],[data-q-hold]').forEach(b=>b.onclick=()=>act(async()=>{
  await api('quarantine',{action:b.dataset.qRestore?'restore':'hold',id:b.dataset.qRestore||b.dataset.qHold});
  notice(b.dataset.qRestore?'元の場所へ復元しました':'30日保持を延長しました');await refresh();
 }));
}
async function loadQuarantineHistory(){
 const q=await api('quarantine');document.querySelector('#quarantine-history')?.remove();
 const panel=document.createElement('div');panel.id='quarantine-history';panel.innerHTML=quarantineHTML(q.items);$('#history').prepend(panel);bindQuarantine(panel,loadQuarantineHistory);
}
const renderHistoryWithoutQuarantine=renderHistory;
renderHistory=()=>{
 const panel=document.querySelector('#quarantine-history');
 renderHistoryWithoutQuarantine();
 if(panel)$('#history').prepend(panel);
 else loadQuarantineHistory().catch(e=>notice(e.message,true));
};
document.addEventListener('click',e=>{if(e.target.closest('button')?.dataset.view==='history')act(loadQuarantineHistory);});
assistantNav.onclick=()=>{setView('assistant');$('#page-title').textContent='AIで片付ける';$('#subtitle').textContent='調査と判断はAIに。最後の完全削除は、あなたに。';loadAssistant();};
async function loadAssistant(){
 if(assistantWorking)return;
 try{
  const {report:r,receipt,operation:op,progress:p,disk}=await api('assistant');
  op.running=op.running||p.running;
  const quarantine=await api('quarantine');
  const eligible=op.running?[]:(r.rows||[]).filter(x=>x.ready),keep=(r.rows||[]).filter(x=>!x.ready);
  const fresh=r.at&&Date.now()/1000-r.at<1800&&r.review?.status==='reviewed';
  assistantSection.innerHTML=`<div class="assistant-hero"><div><span class="eyebrow">このMacのストレージ</span><h2>次の作業に、余白を。</h2><p>使用中のデータと原本を残し、不要な一時データを探します。<br>AIが整理案を作り、最後の完全削除はあなたが決めます。</p></div><div class="assistant-capacity"><span>現在の空き容量</span><strong>${bytes(disk.free)}</strong><progress max="${disk.total}" value="${disk.used}" aria-label="使用済み容量"></progress><small>${bytes(disk.total)} 中 ${bytes(disk.used)} 使用</small></div></div>
   <div id="assistant-activity" class="assistant-activity" role="status" hidden><div><strong id="assistant-activity-text"></strong><span id="assistant-count"></span></div><progress id="assistant-meter"></progress><p>場所を探す → 保持元を照合 → AIが判断 → あなたが確認</p></div>
   <div class="panel"><button id="assistant-start" class="primary" ${op.running?'disabled':''}>${op.running?'AIが調べて、整理案を作っています…':'AIで片付ける'}</button><p role="status">${esc(op.error||r.review?.error||(op.running?'使用状況と再生成元を確認しています。':'調べる・判断する・削除案を作るところまで、自動で進めます。'))}</p><p class="muted">原本・作業履歴・実行環境・使用中のデータは保持します。Codexには種類と容量などの判定情報だけを送り、パスとファイル内容は送りません。</p></div>
   <div class="metrics"><div class="metric"><span>計測時の空き容量</span><strong>${bytes(r.free)}</strong><p>${r.at?new Date(r.at*1000).toLocaleString('ja-JP'):'未計測'}</p></div><div class="metric"><span>AIが選んだ削除候補</span><strong>${bytes(eligible.reduce((n,x)=>n+(x.bytes||0),0))}</strong><p>${eligible.length}か所。実際に空く容量とは異なる場合があります。</p></div><div class="metric"><span>前回の実行前後の空き容量差</span><strong>${bytes(receipt.free_delta)}</strong><p>他の作業による増減を含みます。</p></div></div>
   ${r.at&&!op.running?`<div class="panel"><h3>AIの整理案 · ${eligible.length}件</h3>${!fresh?'<p class="assistant-warning">整理案の期限が切れています。AIで再確認してください。</p>':''}${eligible.length?assistantDetails(eligible):'<p>いま安全に削除できると確認した候補はありません。作業中・変更直後・判定できないデータは保持しました。</p>'}<p class="muted">実際のモデル：${esc((r.review?.runs||[]).join(' → ')||'判定未完了')}。利用枠・既存クレジットはCodexの契約に従います。</p>${r.render_error?`<p>レンダリング一時データは保持：${esc(r.render_error)}</p>`:''}</div>`:''}
   ${r.at?`<div class="panel"><h3>調べた範囲</h3><p>${r.locations||r.rows?.length||0}か所を計測・分類、うち${r.ai_locations??'—'}か所をAIで判断。</p><p>${esc(r.scope||'')}${r.discovery_limited?' 探索上限があるため未調査の場所があります。':''}</p><details><summary>容量の大きい保存場所（原本を含むため保持）</summary>${(r.large_locations||[]).map(x=>`<div class="process"><div><strong>${esc(x.title)}</strong><p class="path">${esc(x.path)}</p></div><strong>${bytes(x.bytes)}</strong></div>`).join('')}<p>親子のフォルダには重複があるため合計しません。大きいだけでは削除候補にしません。</p></details></div>`:''}
   <details class="panel"><summary>保持したデータと理由（${keep.length}か所）</summary><label>名前・場所・理由で探す<input id="assistant-filter" type="search" placeholder="プロジェクト名、使用中、監査記録…"></label><div id="assistant-kept"></div></details>
   ${Object.keys(r.unreadable_locations||{}).length?`<div class="panel"><h3>読み取りできなかった場所は保持しました</h3><p>権限の確認・接続待ちなどで時間内に読み取れない場所をスキップしました。原因は断定せず、削除候補にはしません。</p>${Object.entries(r.unreadable_locations).slice(0,20).map(([path,reason])=>`<p class="path">${esc(path)}<br>${esc(reason)}</p>`).join('')}</div>`:''}
   ${quarantineHTML(quarantine.items,op.running)}
   ${receipt.at?`<div class="panel"><h3>前回の実行結果</h3><p>${new Date(receipt.at*1000).toLocaleString('ja-JP')} ／ ${receipt.status==='completed'?'整理完了':'一部を保持・結果を確認してください'}</p>${(receipt.items||[]).map(x=>`<p>${esc(x.title)}：${x.status==='removed'?'削除済み':esc(x.reason||x.status)}</p>`).join('')}<p>削除対象の計測量 ${bytes(receipt.removed_bytes)} ／ 空き容量 ${bytes(receipt.before_free)} → ${bytes(receipt.after_free)}</p></div>`:''}`;
  bindQuarantine(assistantSection,loadAssistant);
  const renderKept=()=>{const query=$('#assistant-filter').value.toLocaleLowerCase();const found=keep.filter(x=>[x.title,x.path,x.reason,x.ai_reason].join(' ').toLocaleLowerCase().includes(query));$('#assistant-kept').innerHTML=`<p>${found.length}件${found.length>80?' · 先頭80件を表示。検索で絞り込めます。':''}</p>`+assistantDetails(found.slice(0,80));};
  $('#assistant-filter').oninput=renderKept;renderKept();paintAssistantActivity({operation:op,progress:p});
  if(op.running){const metric=assistantSection.querySelectorAll('.metric')[1];metric.querySelector('strong').textContent='確認中';metric.querySelector('p').textContent='新しい照合が終わるまで、前回の候補は使いません。';}
  // Detailed model mechanics belong in the result, not beside the main action.
  if(quarantine.external?.length){
   const external=document.createElement('details');external.className='panel';
   external.innerHTML=`<summary>別セッションの隔離台帳外の記録（${quarantine.external.length}件）</summary><p>取り込み済みの監査記録です。ゴミ箱など別の保存先は、隔離データと混ぜて削除しません。</p>${quarantine.external.map(x=>`<p><strong>${esc(x.audit)} / ${esc(x.id)}</strong><br>${esc(x.path)}<br>${esc(x.reason)}</p>`).join('')}`;
   assistantSection.append(external);
  }
  if(!op.running&&Object.keys(r.unreadable_locations||{}).length&&window.webkit?.messageHandlers?.refresh){
   const access=document.createElement('button');access.textContent='作業フォルダの読み取りを許可';
   access.onclick=()=>act(async()=>{const result=await window.webkit.messageHandlers.refresh.postMessage({action:'folder-access'});notice(result.granted?'許可した場所を「AIで片付ける」で再確認できます。':'許可を変更していません。');});
   assistantSection.querySelector('.panel').append(access);
  }
  if(!op.running&&eligible.length&&fresh){
   const confirm=document.createElement('button');confirm.textContent='まとめて削除内容を確認';confirm.className='primary';
   confirm.onclick=()=>act(()=>requestAssistantPlan(eligible.map(x=>x.id)));
   assistantSection.querySelector('.panel').append(confirm);
   $('#assistant-start').classList.remove('primary');$('#assistant-start').textContent='もう一度AIで調べる';
  }
  $('#assistant-start').onclick=()=>act(async()=>{
   assistantStarted=Date.now();
   await api('assistant',{action:'prepare',primary:'sol',reviewer:'terra'});
   assistantAwaitingReview=true;await loadAssistant();poll();
  });
  clearTimeout(assistantTimer);
  if(op.running||p.running)assistantTimer=setTimeout(watchAssistant,1000);
  else if(assistantAwaitingReview&&currentView==='assistant'){
   assistantAwaitingReview=false;
   if(eligible.length){
    await requestAssistantPlan(eligible.map(x=>x.id));
   }
  }
 }catch(e){assistantAwaitingReview=false;notice(e.message,true);}
}
function showAssistantPlan(plan){
 clearTimeout(assistantExpiryTimer);assistantDialog.className='assistant-confirmation';
 assistantDialog.innerHTML=`<button class="close" aria-label="閉じる">×</button><span class="eyebrow">最後の確認</span><h2>${bytes(plan.bytes)} のデータを完全削除</h2><p>${plan.entries.length}件の候補と保持元を再照合しました。各項目を開くと、対象の場所と再生成方法を確認できます。</p><div class="assistant-plan-list">${assistantDetails(plan.entries)}</div><p class="assistant-warning">ゴミ箱を経由せず、元に戻せません。必要になった場合は、保持元から再生成または再ダウンロードします。</p><div class="assistant-confirm-footer"><p class="assistant-live" role="status"></p><button id="assistant-execute" class="primary">完全削除する</button> <button id="assistant-cancel">今回は削除しない</button></div>`;
 let applying=false;
 const cancel=()=>{if(applying)return;clearTimeout(assistantExpiryTimer);assistantDialog.close();};
 assistantDialog.querySelector('.close').onclick=cancel;$('#assistant-cancel').onclick=cancel;
 assistantDialog.oncancel=e=>{if(applying)e.preventDefault();else clearTimeout(assistantExpiryTimer);};
 const expiry=()=>{const remaining=Math.max(0,Math.ceil(plan.at+300-Date.now()/1000));const b=$('#assistant-execute');if(!b||applying)return;assistantDialog.querySelector('.assistant-live').textContent=remaining?`確認の有効期限：あと ${Math.floor(remaining/60)}分${remaining%60}秒`:'確認期限が切れました。閉じて「まとめて削除内容を確認」から再照合してください。';b.disabled=!remaining;if(remaining)assistantExpiryTimer=setTimeout(expiry,1000);};
 $('#assistant-execute').onclick=()=>act(async()=>{
  applying=true;clearTimeout(assistantExpiryTimer);assistantDialog.querySelectorAll('button').forEach(b=>b.disabled=true);
  assistantDialog.querySelector('.assistant-live').textContent='使用状況を最終照合して処理しています。完了までお待ちください。';
  try{await api('assistant',{action:'apply',ticket:plan.id});assistantDialog.close();await loadAssistant();}
  finally{applying=false;assistantDialog.querySelectorAll('button').forEach(b=>b.disabled=false);$('#assistant-execute').disabled=true;}
 });
 if(!assistantDialog.open)assistantDialog.showModal();expiry();
}
assistantNav.click();
