'use strict';
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
      <h2>Macに、ひと息。</h2>
      <p>急に減った空き容量。<br>いま何が膨らんでいるか、まず見てみましょう。</p>
      <button class="primary pressure-button" data-pressure ${busy?'disabled':''}>↻ いまの膨らみをチェック</button>
      <small>ファイルの削除やアプリの終了は行いません</small>
    </div>
    <div class="pressure-caption"><span>${p ? 'チェック済み · '+esc(date(p.at)) : 'フォルダ全体のスキャンなしで確認できます'}</span><span>${s?.boot_epoch ? '前回の起動 '+esc(date(s.boot_epoch*1000)) : ''}</span></div>
    <div class="metrics pressure-metrics">
      <div class="metric"><span>メモリの代わりに使うディスク</span><strong>${bytes(s?.swap_used)}</strong><p>スワップ · 搭載メモリ ${bytes(s?.ram)}</p></div>
      <div class="metric"><span>削除後もアプリが開いているファイル</span><strong>${bytes(opened?.bytes)}</strong><p>${opened ? measured ? '確認できた '+opened.file_count+' 個 · 論理サイズ' : '一部のみ確認。全体の量は不明です' : 'チェックすると確認できます'}</p></div>
      <div class="metric"><span>いま使える空き容量</span><strong>${bytes(s?.free)}</strong><p>${esc(change)}</p></div>
    </div>
    ${previous ? `<div class="pressure-change" role="status"><strong>${p.boot_changed ? '前回のチェック後に、Macが再起動されています。' : '前回のチェックと比べてみる'}</strong><p>${esc(date(previous.at))} の空き ${bytes(previous.free)} → 今 ${bytes(s.free)}<br>スワップ ${bytes(previous.swap_used)} → ${bytes(s.swap_used)}</p><small>他の作業の増減も含みます。掃除だけの効果とは限りません。</small></div>` : ''}
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
        <div class="panel"><h3>メモリを使っているプロセス</h3><p class="muted">メモリ（RSS）の参考値です。終了すると戻るディスク容量ではありません。</p>${s?.processes?.length ? s.processes.slice(0,6).map(x=>`<div class="process"><span>${esc(x.name)} <small>PID ${x.pid}</small></span><strong>${bytes(x.bytes)}</strong></div>`).join('') : '<p class="muted">チェックすると表示します。</p>'}</div>
      </div>
    </div>
    ${samples.length ? `<div class="panel"><h3>ひと息の記録</h3><p class="muted">次に容量が減ったときもチェックすると、起動日時・スワップ・空きの変化を比較できます。</p><div class="pressure-history">${samples.map(x=>`<div><span>${esc(date(x.at))}</span><strong>空き ${bytes(x.free)}</strong><small>スワップ ${bytes(x.swap_used)}</small></div>`).join('')}</div></div>` : ''}
    <details class="panel"><summary>スナップショットと計測の範囲</summary><pre>${esc(s?.snapshots ?? 'まだ確認していません')}</pre><p class="muted">復元用スナップショットの回収可能量は未計測です。今朝など、最初の計測より前の容量変化は遡って確定できません。管理者権限が必要な領域やAPFSの共有領域も、この数値だけでは説明できません。</p></details>`;
}

document.addEventListener('click', e => {
  if (!e.target.closest('[data-pressure]')) return;
  act(async () => {
    document.querySelectorAll('[data-pressure]').forEach(b=>{b.disabled=true;b.classList.add('checking');});
    notice('Macのいまを確認しています…');
    try {
      const result = await api('pressure', {});
      await load();
      notice(`チェックできました。空き容量は ${bytes(result.system.free)} です。`);
    } finally {
      document.querySelectorAll('[data-pressure]').forEach(b=>{b.disabled=false;b.classList.remove('checking');});
    }
  });
});
