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
   <div class="panel"><h3>元素材を残して片付ける</h3><p>対象は登録済みRemotionプロジェクトの一時コピーです。異なる内容は保持します。完全削除したコピーは元素材から再生成できますが、ゴミ箱からは復元できません。</p><p>一次判定：${esc(s.config.primary || '未設定')} ／ 再確認：${esc(s.config.reviewer || '未設定')}。実際のモデル：${esc((s.review.runs || []).join(', ') || '未実行')}</p>
   <button id="care-review" ${s.operation.running ? 'disabled' : ''}>候補を確認</button> <button id="care-apply" class="primary" ${s.operation.running ? 'disabled' : ''}>検証済みコピーを削除して容量を回収</button><p role="status">${s.operation.running ? '照合・判定中です。画面を開いたままお待ちください。' : esc(s.operation.error || s.review.error || '使用中・不明・AI判定失敗の項目は保持します。')}</p></div>
   <h3>今回の対象と保持理由</h3>${(r.items || []).map(x => `<div class="process"><div><strong>${esc(x.name)}</strong><p>${esc(reasons(x.reason))}</p></div><strong>${bytes(x.bytes)}</strong></div>`).join('')}`;
  $('#care-review').onclick = () => startCare(false);
  $('#care-apply').onclick = () => startCare(true);
  clearTimeout(careTimer);
  if (s.operation.running) careTimer = setTimeout(loadCare, 2000);
 } catch(e) { notice(e.message, true); }
}
async function startCare(apply) {
 await act(async () => { await api('render-care', {apply}); await loadCare(); });
}
