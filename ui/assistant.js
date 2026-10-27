'use strict';
const assistantStyles=document.createElement('link');assistantStyles.rel='stylesheet';assistantStyles.href='/assistant.css';document.head.append(assistantStyles);
const assistantNav=document.createElement('button');
assistantNav.textContent='✧ AIで片付ける';assistantNav.dataset.view='assistant';
document.querySelector('nav').prepend(assistantNav);
const assistantSection=document.createElement('section');
assistantSection.id='assistant';assistantSection.className='view';assistantSection.hidden=true;
document.querySelector('main').insertBefore(assistantSection,document.querySelector('.main-footer'));
const assistantDialog=document.createElement('dialog');document.body.append(assistantDialog);
let assistantTimer,assistantAwaitingReview=false;
assistantNav.onclick=()=>{setView('assistant');$('#page-title').textContent='AIで片付ける';$('#subtitle').textContent='調査と判断はAIに。最後の完全削除は、あなたに。';loadAssistant();};
async function loadAssistant(){
 try{
  const {report:r,receipt,operation:op}=await api('assistant');
  const eligible=(r.rows||[]).filter(x=>x.ready),keep=(r.rows||[]).filter(x=>!x.ready);
  assistantSection.innerHTML=`<div class="intro"><h2>片付けは、AIに任せる。</h2><p>このMacを調べ、残すものと削除できるものを判断します。<br>削除する内容を最後に確認するまで、ファイルは消しません。</p></div>
   <div class="panel"><button id="assistant-start" class="primary" ${op.running?'disabled':''}>${op.running?'AIが調べて、整理案を作っています…':'AIで片付ける'}</button><p role="status">${esc(op.error||r.review?.error||(op.running?'使用状況と再生成元を確認しています。':'調べる・判断する・削除案を作るところまで、自動で進めます。'))}</p><p class="muted">原本・作業履歴・実行環境・使用中のデータは保持します。Codexには種類と容量などの判定情報だけを送り、パスとファイル内容は送りません。</p></div>
   <div class="metrics"><div class="metric"><span>計測時の空き容量</span><strong>${bytes(r.free)}</strong><p>${r.at?new Date(r.at*1000).toLocaleString('ja-JP'):'未計測'}</p></div><div class="metric"><span>AIが選んだ削除候補</span><strong>${bytes(eligible.reduce((n,x)=>n+(x.bytes||0),0))}</strong><p>${eligible.length}か所。実際に空く容量とは異なる場合があります。</p></div><div class="metric"><span>前回の実行前後の空き容量差</span><strong>${bytes(receipt.free_delta)}</strong><p>他の作業による増減を含みます。</p></div></div>
   ${r.at&&!op.running?`<div class="panel"><h3>AIの整理案</h3>${eligible.length?eligible.map(x=>`<div class="process"><div><strong>${esc(x.title)}</strong><p>${esc(x.ai_reason||x.reason)}</p></div><strong>${bytes(x.bytes)}</strong></div>`).join(''):'<p>いま安全に削除できると確認した候補はありません。作業中・変更直後・判定できないデータは保持しました。</p>'}<p class="muted">実際のモデル：${esc((r.review?.runs||[]).join(' → ')||'判定未完了')}。利用枠・既存クレジットはCodexの契約に従います。</p>${r.render_error?`<p>レンダリング一時データは保持：${esc(r.render_error)}</p>`:''}</div>`:''}
   ${r.at?`<div class="panel"><h3>調べた範囲</h3><p>${r.locations||r.rows?.length||0}か所を計測・分類、うち${r.ai_locations??'—'}か所をAIで判断。</p><p>${esc(r.scope||'')}${r.discovery_limited?' 探索上限があるため未調査の場所があります。':''}</p><details><summary>容量の大きい保存場所（原本を含むため保持）</summary>${(r.large_locations||[]).map(x=>`<div class="process"><div><strong>${esc(x.title)}</strong><p class="path">${esc(x.path)}</p></div><strong>${bytes(x.bytes)}</strong></div>`).join('')}<p>親子のフォルダには重複があるため合計しません。大きいだけでは削除候補にしません。</p></details></div>`:''}
   <details class="panel"><summary>保持したデータと理由（${keep.length}か所）</summary>${keep.map(x=>`<div class="process"><div><strong>${esc(x.title)}</strong><p class="path">${esc(x.path)}</p><p>${esc(x.reason)}${x.ai_reason?' ／ '+esc(x.ai_reason):''}</p></div><strong>${bytes(x.bytes)}</strong></div>`).join('')}</details>
   ${receipt.at?`<div class="panel"><h3>前回の実行結果</h3><p>${new Date(receipt.at*1000).toLocaleString('ja-JP')} ／ ${receipt.status==='completed'?'整理完了':'一部を保持・結果を確認してください'}</p>${(receipt.items||[]).map(x=>`<p>${esc(x.title)}：${x.status==='removed'?'削除済み':esc(x.reason||x.status)}</p>`).join('')}<p>削除対象の計測量 ${bytes(receipt.removed_bytes)} ／ 空き容量 ${bytes(receipt.before_free)} → ${bytes(receipt.after_free)}</p></div>`:''}`;
  $('#assistant-start').onclick=()=>act(async()=>{
   await api('assistant',{action:'prepare',primary:'sol',reviewer:'terra'});
   assistantAwaitingReview=true;await loadAssistant();poll();
  });
  clearTimeout(assistantTimer);
  if(op.running)assistantTimer=setTimeout(loadAssistant,2000);
  else if(assistantAwaitingReview&&currentView==='assistant'){
   assistantAwaitingReview=false;
   if(eligible.length)showAssistantPlan(await api('assistant',{action:'plan',ids:eligible.map(x=>x.id)}));
  }
 }catch(e){assistantAwaitingReview=false;notice(e.message,true);}
}
function showAssistantPlan(plan){
 assistantDialog.innerHTML=`<button class="close" aria-label="閉じる">×</button><h2>この内容で完全削除しますか？</h2><p>AIとローカル検証で選んだ ${plan.entries.length}か所・計測量 ${bytes(plan.bytes)} です。</p>${plan.entries.map(x=>`<div class="detail-block"><strong>${esc(x.title)}</strong><p class="wrap">${esc(x.path)}</p><p>${bytes(x.bytes)} ／ ${esc(x.reason)}</p></div>`).join('')}<p>ゴミ箱を経由せず削除するため、元に戻せません。必要時は保持した元データから再生成、または再ダウンロードします。</p><p>確認は5分間有効。変更や使用中を検出した対象は保持します。</p><button id="assistant-execute" class="primary">この内容で完全削除する</button> <button id="assistant-cancel">今回は削除しない</button>`;
 assistantDialog.querySelector('.close').onclick=()=>assistantDialog.close();
 $('#assistant-cancel').onclick=()=>assistantDialog.close();
 $('#assistant-execute').onclick=()=>act(async()=>{
  const b=$('#assistant-execute');b.disabled=true;
  try{await api('assistant',{action:'apply',ticket:plan.id});assistantDialog.close();await loadAssistant();}
  finally{b.disabled=false;}
 });
 assistantDialog.showModal();
}
assistantNav.click();
