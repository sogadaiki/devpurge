'use strict';
let refreshApps = [], refreshSessions = [], pressureWatching = false, pressureTimer = null;
const nativeRefresh = data => window.webkit.messageHandlers.refresh.postMessage(data);
const hasNativeRefresh = () => !!window.webkit?.messageHandlers?.refresh;
function updateRefreshBusy() {
  document.querySelectorAll('[data-pressure],[data-app-rest],[data-app-check],[data-pressure-watch]').forEach(b=>b.disabled=busy||!!state.progress?.running);
}
function temporaryLabel(temporary) {
  if(!temporary)return '未計測';
  if(temporary.bytes!=null)return bytes(temporary.bytes);
  const known=(temporary.regions||[]).filter(r=>r.observed_bytes!=null);
  return known.length?'確認できた範囲 '+bytes(known.reduce((n,r)=>n+r.observed_bytes,0))+'（一部は未確認）':'未計測';
}
async function loadRefreshApps() {
  if(!hasNativeRefresh())return;
  const native=await nativeRefresh({action:'list'});
  refreshApps=native.apps;refreshSessions=native.sessions||[];
}
function appMemory(app) {
  const all = state.pressure?.system?.process_tree || [], ids = new Set([app.pid]);
  // Reparented helpers cannot reliably be attributed and remain in the process list.
  for (let n=0; n<12; n++) { const size=ids.size; all.forEach(p=>{if(ids.has(p.parent))ids.add(p.pid);}); if(size===ids.size)break; }
  const rows=all.filter(p=>ids.has(p.pid)), known=rows.filter(p=>p.footprint!=null);
  return {bytes:known.length?known.reduce((sum,p)=>sum+p.footprint,0):null,partial:known.length!==rows.length, count:rows.length};
}
function renderRestApps() {
  if (!hasNativeRefresh()) return '<p class="muted">Macアプリ版では、保存を確認して一つずつ通常終了できます。ブラウザ版では、アプリを手動で終了して再チェックしてください。</p>';
  if (!refreshApps.length) return '<p class="muted">「いまの膨らみをチェック」で、起動中のアプリを確認します。</p>';
  const rows=refreshApps.map(a=>({...a,memory:appMemory(a)})).sort((a,b)=>(b.memory.bytes||0)-(a.memory.bytes||0));
  const row=a=>`<div class="rest-app"><div><strong>${esc(a.name)}</strong><small>${bytes(a.memory.bytes)}${a.memory.partial?' 以上':''} · メモリ参考値${a.memory.count>1?' / 関連 '+a.memory.count+' プロセス':''}</small>${a.protected?`<small class="keep-tag">${esc(a.protected)}</small>`:''}</div><div class="rest-actions"><button class="text-button" data-app-focus="${esc(a.ticket)}">開いて保存</button>${a.protected?'':`<button class="primary" data-app-rest="${esc(a.ticket)}">ひと休み →</button>`}</div></div>`;
  const eligible=rows.filter(a=>!a.protected), kept=rows.filter(a=>a.protected);
  return eligible.slice(0,5).map(row).join('')+(eligible.length>5?`<details><summary>ほかの ${eligible.length-5} アプリ</summary>${eligible.slice(5).map(row).join('')}</details>`:'')+`<details class="kept-apps"><summary>作業を守って起動を保つ · ${kept.length} アプリ</summary>${kept.map(row).join('')}</details>`;
}
function renderRestHistory() {
  const labels={completed:'通常終了を確認しました',waiting:'終了待ち・キャンセルの可能性',refused:'終了要求が受け付けられませんでした',prepared:'終了結果は未確認です',exited_unmeasured:'通常終了済み・再計測が必要です'};
  return (state.native_refresh||[]).slice(0,6).map(r=>{
    const delta=r.after?.free!=null&&r.before?.free!=null?r.after.free-r.before.free:null;
    const check=r.status==='waiting'?(refreshSessions.includes(r.id)?`<button class="primary" data-app-check="${esc(r.id)}">終了したか確認する</button><p class="muted">アプリ側の保存確認を済ませてから押してください。キャンセルしたアプリには再要求しません。</p>`:'<p class="muted">起動し直す前の記録は、自動で完了扱いにしません。「いまの膨らみをチェック」で現在の状態を確認できます。</p>'):'';
    return `<div class="rest-receipt"><span class="eyebrow">${esc(date(r.at))}</span><h4>${esc(r.name)} · ${esc(labels[r.status]||'結果未確認')}</h4>${delta==null?'<p>空き容量の変化はまだ確定していません。</p>':`<p class="rest-result">${bytes(Math.abs(delta))}<small>空きが${delta>=0?'増えました':'減りました'}</small></p><p class="muted">空き ${bytes(r.before.free)} → ${bytes(r.after.free)}<br>スワップ領域 ${bytes(r.before.vm_volume_bytes)} → ${bytes(r.after.vm_volume_bytes)}</p>`}${check}</div>`;
  }).join('');
}
function renderRefresh() {
  const p = state.pressure, s = p?.system, opened = p?.deleted_open;
  const samples = (state.pressure_history || []).slice(-6).reverse();
  const measured = opened?.status === 'observed';
  const previous = p?.previous;
  const delta = p?.free_delta;
  const change = delta == null ? 'もう一度チェックすると、変化が見えます。' : `前回から ${bytes(Math.abs(delta))} ${delta >= 0 ? '空きが増えました' : '空きが減りました'}。`;
  $('#refresh').innerHTML = `
    <div class="refresh-hero">
      <div class="breath-mark" aria-hidden="true">↻</div>
      <span class="eyebrow">A LITTLE ROOM TO BREATHE</span>
      <h2>再起動の前に、ひと息。</h2>
      <p>急に減った空き容量。<br>いま何が膨らんでいるか、まず見てみましょう。</p>
      <button class="primary pressure-button" data-pressure ${busy?'disabled':''}>↻ いまの膨らみをチェック</button>
      <small>ファイルの削除やアプリの終了は行いません</small>
    </div>
    <div class="pressure-caption"><span>${p ? 'チェック済み · '+esc(date(p.at)) : 'フォルダ全体のスキャンなしで確認できます'}</span><span>${s?.boot_epoch ? '前回の起動 '+esc(date(s.boot_epoch*1000)) : ''}</span></div>
    <div class="metrics pressure-metrics">
      <div class="metric"><span>スワップ用に確保された領域</span><strong>${bytes(s?.vm_volume_bytes)}</strong><p>使用中 ${bytes(s?.swap_used)} · 搭載メモリ ${bytes(s?.ram)}<br>使用量と確保量は重複するため合計しません</p></div>
      <div class="metric"><span>削除後もアプリが開いているファイル</span><strong>${bytes(opened?.bytes)}</strong><p>${opened ? measured ? '確認できた '+opened.file_count+' 個 · 論理サイズ' : '一部のみ確認。全体の量は不明です' : 'チェックすると確認できます'}</p></div>
      <div class="metric"><span>いま使える空き容量</span><strong>${bytes(s?.free)}</strong><p>${esc(change)}</p></div>
    </div>
    <p class="muted transient-note">OSの一時作業フォルダ ${temporaryLabel(p?.temporary)} · 自分の一時領域と共有tmpのファイルを計測。共有領域や未確認分があり、回収できる容量とは異なります。保存途中のデータも含むため、この画面では削除しません。</p>
    ${previous ? `<div class="pressure-change" role="status"><strong>${p.boot_changed ? '前回のチェック後に、Macが再起動されています。' : '前回のチェックと比べてみる'}</strong><p>${esc(date(previous.at))} の空き ${bytes(previous.free)} → 今 ${bytes(s.free)}<br>スワップの確保領域 ${bytes(previous.vm_volume_bytes)} → ${bytes(s.vm_volume_bytes)}</p>${p.comparison?.vm_volume_bytes_decrease>0?`<p>スワップ領域が ${bytes(p.comparison.vm_volume_bytes_decrease)} 縮みました。</p>`:''}<small>他の作業の増減も含みます。掃除だけの効果とは限りません。</small></div>` : ''}
    <div class="panel rest-panel"><span class="eyebrow">ONE APP · ONE BREATH</span><h3>ひとつずつ、休ませる。</h3><p>① アプリを開いて保存　→　② ひと休み　→　③ 戻った空きを実測</p><p class="muted">制作中・書き出し中のアプリは残しましょう。選んだアプリのすべてのウィンドウを通常終了します。確認画面で進むまで終了しません。</p>${renderRestApps()}</div>
    ${state.native_refresh?.length?`<div class="panel"><h3>ひと休みの結果</h3><p class="muted">終了の前後を同じ方法で計測します。他の作業の増減も含み、終了だけの効果とは限りません。</p>${renderRestHistory()}</div>`:''}
    <div class="panel watch-panel"><div><h3>${pressureWatching?'膨らみを見守っています':'次に膨らむ瞬間を、記録する。'}</h3><p class="muted">この画面を開いている間、約5分ごとに容量・スワップ・メモリ上位を記録。最大2,048回をMac内に保持します。${pressureWatching?'アプリを閉じると停止します。':'ファイルの中身は読みません。'}</p></div><button class="${pressureWatching?'text-button':'primary'}" data-pressure-watch>${pressureWatching?'見守りを止める':'見守りを始める'}</button></div>
    <div class="two-column">
      <div class="panel"><span class="eyebrow">SAVE · CLOSE · CHECK</span><h3>再起動の前にできること</h3>
        <p>作業を保存して、使い終えたアプリを通常の操作で終了。そのあと、もう一度チェックします。</p>
        <div class="pressure-explain"><strong>アプリが開いたままのファイル</strong><p>ファイルを削除しても、アプリが開いている間は容量が残ることがあります。終了で解放される候補です。</p></div>
        ${opened?.processes?.length ? opened.processes.map(x=>`<div class="process"><span>${esc(x.name)} <small>PID ${x.pid} · ${x.files}個</small></span><strong>${bytes(x.bytes)}</strong></div>`).join('') : `<p class="muted">${measured ? '確認できる範囲に、該当するファイルはありませんでした。' : 'チェックすると、ファイルを開いているプロセスを表示します。'}</p>`}
        <p class="muted">通常権限で見える範囲の参考値です。同じファイルを複数のプロセスが開く場合があり、行の合計は総量と一致しません。実際に戻る容量は未確定です。</p>
        <div class="pressure-explain"><strong>スワップが大きいとき</strong><p>macOSがメモリの状況に合わせて管理します。作業を保存してアプリを終了しても改善しないときは、再起動を検討します。</p></div>
        <button class="primary" data-pressure ${busy?'disabled':''}>保存・終了後に、もう一度チェック</button>
      </div>
      <div>
        <div class="panel"><span class="eyebrow">PYTHON CARE</span><h3>Pythonのキャッシュをお手入れ</h3><p>uv公式ツールで、使われなくなったキャッシュを整理できます。</p><p class="muted">作業中のPython環境やAIモデルは保持します。キャッシュ内の再作成可能な環境も対象になり得ます。必要時に再取得・再構築し、ゴミ箱からは戻せません。</p><button class="primary" data-refresh>整理する内容を確認 →</button><p class="muted">使用中や更新直後なら、理由を表示して保持します。</p></div>
        <div class="panel"><h3>メモリを使っているプロセス</h3><p class="muted">圧縮分も含むメモリ負荷の参考値です。終了すると戻るディスク容量ではありません。</p>${s?.processes?.length ? s.processes.slice(0,6).map(x=>`<div class="process"><span>${esc(x.name)} <small>PID ${x.pid}</small></span><strong>${bytes(x.footprint)}</strong></div>`).join('') : '<p class="muted">チェックすると表示します。</p>'}</div>
      </div>
    </div>
    ${samples.length ? `<div class="panel"><h3>ひと息の記録</h3><p class="muted">次に容量が減ったときもチェックすると、起動日時・スワップ・空きの変化を比較できます。</p><div class="pressure-history">${samples.map(x=>`<div><span>${esc(date(x.at))}</span><strong>空き ${bytes(x.free)}</strong><small>スワップ ${bytes(x.swap_used)}</small></div>`).join('')}</div></div>` : ''}
    <details class="panel"><summary>スナップショットと計測の範囲</summary><pre>${esc(s?.snapshots ?? 'まだ確認していません')}</pre><p class="muted">復元用スナップショットの回収可能量は未計測です。今朝など、最初の計測より前の容量変化は遡って確定できません。管理者権限が必要な領域やAPFSの共有領域も、この数値だけでは説明できません。</p></details>`;
}

async function checkPressure(quiet=false) {
    document.querySelectorAll('[data-pressure]').forEach(b=>{b.disabled=true;b.classList.add('checking');});
    if(!quiet)notice('Macのいまを確認しています…');
    try {
      const result = await api('pressure', {});
      await loadRefreshApps();
      await load();
      if(!quiet)notice(`チェックできました。空き容量は ${bytes(result.system.free)} です。`);
    } finally {
      document.querySelectorAll('[data-pressure]').forEach(b=>{b.disabled=false;b.classList.remove('checking');});
    }
}
function schedulePressure() {
  clearTimeout(pressureTimer);
  if(!pressureWatching)return;
  pressureTimer=setTimeout(async()=>{if(!busy&&!state.progress?.running)await act(()=>checkPressure(true));schedulePressure();},300000);
}
document.addEventListener('click', e => {
  const b=e.target.closest('button');if(!b)return;
  if(b.hasAttribute('data-pressure'))act(()=>checkPressure());
  if(b.dataset.appFocus)act(()=>nativeRefresh({action:'focus',ticket:b.dataset.appFocus}));
  if(b.dataset.appRest||b.dataset.appCheck)act(async()=>{
    b.disabled=true;
    notice('保存と終了を確認しています。アプリ側の確認画面もご覧ください。');
    try {
      const r=await nativeRefresh(b.dataset.appRest?{action:'quit',ticket:b.dataset.appRest}:{action:'check',id:b.dataset.appCheck});
      if(r.status==='cancelled')notice('このアプリは、そのまま残しました。');
      else notice(r.status==='completed'?'通常終了を確認しました。ひと休みの結果をご覧ください。':'まだ終了の完了を確認できていません。アプリは強制終了しません。');
      await loadRefreshApps();
      await load();
      if(r.status!=='cancelled')document.querySelector('.rest-receipt')?.scrollIntoView({block:'center',behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth'});
    }finally{b.disabled=false;}
  });
  if(b.hasAttribute('data-pressure-watch')){
    if(pressureWatching){pressureWatching=false;schedulePressure();renderRefresh();return;}
    act(async()=>{await checkPressure();pressureWatching=true;schedulePressure();renderRefresh();});
  }
});
