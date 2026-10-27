'use strict';
// Existing Studio layout and API authentication; no file paths are model input.
const careNav = document.createElement('button');
careNav.textContent = '◇ レンダリングの片付け';
careNav.dataset.view = 'care';
document.querySelector('nav').append(careNav);
const careSection = document.createElement('section');
careSection.id = 'care'; careSection.className = 'view'; careSection.hidden = true;
document.querySelector('main').insertBefore(careSection, document.querySelector('.main-footer'));
let careTimer;
careNav.onclick = () => { setView('care'); $('#page-title').textContent = 'レンダリングの片付け'; $('#subtitle').textContent = '作業中の素材を守り、役目を終えたコピーから容量を戻す。'; loadCare(); };
async function loadCare() {
 try {
  const s = await api('render-care');
  const r = s.latest, receipt = s.receipt;
  const when = value => value ? new Date(value * 1000).toLocaleString('ja-JP') : '未計測';
  const reasons = reason => ({'Active renderer/browser or open files; preserved':'レンダリング中の可能性があるため保持', 'Unregistered render intermediate':'元データを確認できていないため保持', 'No identical retained originals; keeping all files':'一致する元データがないため保持', 'Recent bundle; wait at least one hour':'作成直後のため保持', 'Needs retained-original verification':'元データとの照合待ち', 'Identical public copies only; differing files retained':'一致するコピーのみ回収。異なるファイルは保持', 'Public copies match retained originals; generated bundler files only':'元データとの内容一致を確認'}[reason] || reason);
  careSection.innerHTML = `<div class="intro"><h2>空き容量を、実際に取り戻す。</h2><p>Codexが候補を確認し、元素材との内容一致・使用状況をもう一度検査してから、一致する一時コピーを完全に削除します。作業履歴や原本は対象外です。</p></div>
   <div class="metrics"><div class="metric"><span>空き容量</span><strong>${bytes(r.free)}</strong><p>${when(r.at)}</p></div><div class="metric"><span>レンダリング一時領域</span><strong>${bytes(r.temp_bytes)}</strong><p>前回から ${r.growth_bytes == null ? '未比較' : bytes(r.growth_bytes)}</p></div><div class="metric"><span>前回の整理前後の空き容量差</span><strong>${bytes(receipt.free_delta)}</strong><p>削除したコピー ${bytes(receipt.removed_bytes)}。他の作業による増減を含みます。</p></div></div>
   <div class="panel"><h3>元素材を残して片付ける</h3><p>対象は登録済みRemotionプロジェクトの一時コピーです。異なる内容は保持します。完全削除したコピーは元素材から再生成できますが、ゴミ箱からは復元できません。</p><p>一次判定：${esc(s.config.primary || '未設定')} ／ 再確認：${esc(s.config.reviewer || '未設定')}。実際のモデル：${esc((s.review.runs || []).join(', ') || '今回は判定対象なし')}</p><p>定期実行の最終確認：${when(s.service?.at)}${s.service?.error ? ' ／ '+esc(s.service.error) : ''}${s.service?.at && Date.now()/1000-s.service.at > 1200 ? ' ／ 20分以上経過。動作を確認してください。' : ''}</p>
   <button id="care-review" ${s.operation.running ? 'disabled' : ''}>候補を確認</button> <button id="care-apply" class="primary" ${s.operation.running ? 'disabled' : ''}>検証済みコピーを削除して容量を回収</button><p role="status">${s.operation.running ? '照合・判定中です。画面を開いたままお待ちください。' : esc(s.operation.error || s.review.error || '使用中・不明・AI判定失敗の項目は保持します。')}</p></div>
   <div class="panel"><h3>終了した処理がつかんでいる容量を戻す</h3><p>終了したレンダリングの専用ブラウザを確認します。親処理・制御接続・ページサーバーが終了したことを確認できた場合だけ、通常の終了を要求できます。使用中・不明な処理は保持します。</p><button id="job-scan">終了済みの残骸を確認</button><div id="job-result" role="status"></div><p>回収後に上の「検証済みコピーを削除」で、一時コピーも整理できます。スワップの縮小はmacOSが管理するため、即時の回収量は保証されません。</p></div>
   <h3>今回の対象と保持理由</h3>${(r.items || []).map(x => `<div class="process"><div><strong>${esc(x.name)}</strong><p>${esc(reasons(x.reason))}</p></div><strong>${bytes(x.bytes)}</strong></div>`).join('')}`;
  $('#care-review').onclick = () => startCare(false);
  $('#care-apply').onclick = () => startCare(true);
  $('#job-scan').onclick = () => jobAction({action:'scan'});
  showJobs(await api('job-recovery'));
  clearTimeout(careTimer);
  if (s.operation.running) careTimer = setTimeout(loadCare, 2000);
 } catch(e) { notice(e.message, true); }
}
function showJobs(s) {
 const target = $('#job-result');
 if (!target) return;
 target.innerHTML = `<p>${s.at ? new Date(s.at*1000).toLocaleString('ja-JP') : '未確認'}。操作の有効期限は確認から5分です。</p>` + (s.items || []).map(x => `<div class="process"><div><strong>Remotion専用ブラウザ PID ${Number(x.pid)}</strong><p>${esc(x.reason)}</p></div>${x.ready ? `<button data-job="${esc(x.id)}">この終了済みブラウザを閉じて回収</button>` : '<span>保持</span>'}</div>`).join('') + (s.at && !s.items.length ? '<p>回収対象の孤立ブラウザはありません。</p>' : '') + (s.receipt?.at ? `<p>前回：${esc(({closed:'終了を確認しました',requested:'終了要求を記録',not_closed_no_force:'終了未確認。強制終了していません',failed_no_force:'終了要求に失敗。強制終了していません'})[s.receipt.status] || s.receipt.status)} ／ 空き容量差 ${bytes(s.receipt.free_delta)}（他の作業による増減を含む）</p>` : '');
 target.querySelectorAll('[data-job]').forEach(b => { b.onclick = () => jobAction({action:'apply',ticket:b.dataset.job}); });
}
async function jobAction(data) {
 await act(async () => {
  $('#job-scan').disabled = true;
  $('#job-result').querySelectorAll('button').forEach(b => { b.disabled = true; });
  try { showJobs(await api('job-recovery',data)); }
  finally { $('#job-scan').disabled = false; }
 });
}
async function startCare(apply) {
 await act(async () => { await api('render-care', {apply}); await loadCare(); });
}
