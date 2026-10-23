'use strict';

// A tiny, evidence-based daily ritual. The reward is for attention, never deletion.
let soundEnabled = localStorage.getItem('devpurge-sound') === 'on';
let dailyWasScanning = false;
let dailyFinishing = false;
let dailyMotionTimer;

function chime(kind = 'soft') {
  if (!soundEnabled) return;
  try {
    const Audio = window.AudioContext || window.webkitAudioContext;
    const audio = new Audio();
    const notes = kind === 'finish' ? [523.25, 659.25, 783.99] : [659.25, 783.99];
    notes.forEach((frequency, index) => {
      const oscillator = audio.createOscillator();
      const gain = audio.createGain();
      oscillator.type = 'sine'; oscillator.frequency.value = frequency;
      oscillator.connect(gain); gain.connect(audio.destination);
      const start = audio.currentTime + index * .09;
      gain.gain.setValueAtTime(0, start);
      gain.gain.linearRampToValueAtTime(.055, start + .012);
      gain.gain.exponentialRampToValueAtTime(.001, start + .32);
      oscillator.start(start); oscillator.stop(start + .35);
    });
    setTimeout(() => audio.close(), 900);
  } catch (_) { /* Sound is a preference, never a required capability. */ }
}

function weekStamps(daily) {
  const today = daily?.today || new Date().toLocaleDateString('en-CA');
  const [year, month, day] = today.split('-').map(Number);
  return Array.from({ length: 7 }, (_, n) => {
    const d = new Date(year, month - 1, day - 6 + n);
    const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
    const complete = daily?.days?.some(row => row.day === key && row.completed_at);
    return `<div class="stamp ${complete ? 'stamped' : ''} ${key === today ? 'is-today' : ''}"><span>${complete ? '✦' : '·'}</span><small>${key === today ? '今日' : `${d.getMonth() + 1}/${d.getDate()}`}</small></div>`;
  }).join('');
}

function dailyCandidate() {
  const items = state.result?.items || [];
  return [...items].filter(i => i.bytes > 0 && i.action === 'trash').sort((a, b) => (b.delta || 0) - (a.delta || 0) || b.bytes - a.bytes)[0]
    || items.find(i => i.bytes > 0 && i.category === 'intermediate')
    || items.find(i => i.bytes > 0);
}

function renderDaily() {
  const host = $('#today');
  if (!host) return;
  const focusedId = host.contains(document.activeElement) ? document.activeElement.id : null;
  const daily = state.daily;
  const scanned = !!daily?.current?.scan_at;
  const complete = !!daily?.current?.completed_at;
  const running = !!state.progress?.running;
  const candidate = dailyCandidate();
  const free = state.result?.system?.free;
  const stage = running ? 'scanning' : complete ? 'complete' : scanned ? 'ready' : 'idle';
  const message = running ? '隅々まで、見まわり中。' : complete ? '今日も、おつかれさま。' : scanned ? 'ちゃんと、見えてきました。' : '今日も、ひと掃除しよう。';
  host.dataset.stage = stage;
  host.innerHTML = `
    <div class="daily-topline"><span class="daily-day">✦ YOUR DAILY RESET</span><button id="sound-toggle" class="sound-toggle" aria-pressed="${soundEnabled}">${soundEnabled ? '♫ 音 ON' : '♪ 音 OFF'}</button></div>
    <div class="daily-scene">
      <div class="daily-copy"><span class="daily-greeting">${esc(message)}</span><h2>${complete ? 'すっきり。<br>また、作ろう。' : 'ひと掃除で、<br>気分も、軽く。'}</h2><p>${running ? 'ファイルの役割と、増えた場所を調べています。<br>大切なデータは、そのまま。' : complete ? '今日の状態を確認して、ひとつ判断できました。<br>続きはまた、気が向いたときに。' : '溜まったものを知って、ひとつ整える。<br>Macとあなたの、小さなお手入れ時間。'}</p>
      <button class="daily-start" id="daily-start" ${running || busy ? 'disabled' : ''}><span>${running ? '<i class="mini-orbit"></i> 見まわり中' : complete ? 'もう一度チェック' : scanned ? '見つかったものを見る' : '今日のお手入れをはじめる'}</span><b>${running ? '' : '→'}</b></button>
      <span class="daily-promise">${running ? 'ほかの作業を続けても大丈夫です' : scanned ? '無理に消さなくても、いいんです。' : 'まずは調べるだけ。勝手には消しません。'}</span>
      </div>
      <div class="companion-stage"><div class="scene-glow"></div><div class="scene-orbit orbit-one"></div><div class="scene-orbit orbit-two"></div><button class="companion" id="companion" aria-label="お掃除の相棒をなでる"><img src="/assets/companion.png" width="1254" height="1254" alt="ほうきを持った小さなお掃除ロボと、元気な植物" draggable="false"></button><span class="companion-bubble" id="companion-bubble">${complete ? 'いい一日を！' : running ? 'まかせて。' : scanned ? '見つけたよ！' : 'いっしょに、こつこつ。'}</span><span class="scene-spark spark-one">✧</span><span class="scene-spark spark-two">✦</span><span class="scene-spark spark-three">✧</span></div>
    </div>
    <div class="daily-steps" aria-label="今日のお手入れの進み具合"><div class="${scanned ? 'done' : 'current'}"><span>${scanned ? '✓' : '1'}</span><strong>しらべる</strong><small>今のMacを知る</small></div><i></i><div class="${complete ? 'done' : scanned ? 'current' : ''}"><span>${complete ? '✓' : '2'}</span><strong>ひとつ決める</strong><small>整理する。残す。</small></div><i></i><div class="${complete ? 'done' : ''}"><span>${complete ? '✦' : '3'}</span><strong>すっきり、おしまい</strong><small>今日のスタンプ</small></div></div>
    <div id="daily-live" class="daily-live ${running ? '' : 'quiet'}" role="status">${running ? `<span class="scan-track"><i id="daily-track"></i></span><span id="daily-progress-label">${esc(state.progress.message)} · ${state.progress.done || 0} / ${state.progress.total || '…'}</span>` : complete ? '✦ 今日のお手入れは完了しています。' : scanned ? '✓ 見まわり完了。次は、ひとつだけ決めましょう。' : 'あなたのペースで。毎日じゃなくても、大丈夫。'}</div>
    <div class="daily-bottom">
      <div class="daily-focus" id="daily-focus">${scanned && !complete ? `<span class="tiny-label">TODAY'S SMALL STEP</span><h3>今日は、この1か所だけ。</h3>${candidate ? `<div class="focus-file"><span class="folder-glyph">▰</span><div><strong>${esc(candidate.title)}</strong><small>${bytes(candidate.bytes)} · ${esc(categories[candidate.category])}</small></div></div><p>${esc(candidate.reason)}</p><div class="focus-actions"><button class="focus-review" data-detail="${candidate.id}">中身と影響を見る ↗</button><button class="focus-keep" id="daily-keep" data-id="${candidate.id}">今日は残して、おしまい ✓</button></div>` : '<p>対象に大きなデータは見つかりませんでした。</p><button class="focus-keep" id="daily-reviewed">確認できたので、おしまい ✓</button>'}` : `<span class="tiny-label">YOUR MAC, RIGHT NOW</span><div class="daily-capacity"><strong>${free === undefined ? '—' : bytes(free)}</strong><span>空き容量</span></div><p>${complete ? '今日は確認して判断した日。データの削除量とは別の記録です。' : '計測した空き容量です。お手入れを続けると、増えた場所も見えてきます。'}</p><button class="subtle-link" data-go="overview">容量の地図をひらく →</button>`}</div>
      <div class="daily-journal"><span class="tiny-label">LITTLE BY LITTLE</span><div class="journal-heading"><h3>お手入れの足あと</h3><span>${daily?.completed_days || 0}<small> 日</small></span></div><div class="stamp-row">${weekStamps(daily)}</div><p>空いた日があっても、足あとは消えません。</p></div>
    </div>`;
  $('#sound-toggle').onclick = () => { soundEnabled = !soundEnabled; localStorage.setItem('devpurge-sound', soundEnabled ? 'on' : 'off'); renderDaily(); if (soundEnabled) chime(); };
  $('#daily-start').onclick = () => {
    chime();
    if (scanned && !complete) { $('#daily-focus').scrollIntoView({ behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth', block: 'center' }); $('#daily-focus').classList.add('focus-pop'); return; }
    act(scan);
  };
  $('#companion').onclick = () => {
    const pet = $('#companion'); pet.classList.remove('petted'); void pet.offsetWidth; pet.classList.add('petted');
    $('#companion-bubble').textContent = ['ちゃんと残すのも、お手入れ。', '今日も、いい感じ。', 'あせらず、ひとつずつ。'][Math.floor(Math.random() * 3)];
    chime();
  };
  if ($('#daily-keep')) $('#daily-keep').onclick = () => finishDaily('keep', candidate.id);
  if ($('#daily-reviewed')) $('#daily-reviewed').onclick = () => finishDaily('reviewed');
  if (scanned && !complete && candidate?.action === 'trash') {
    const button = document.createElement('button');
    button.className = 'focus-clean'; button.textContent = '整理する内容を確認 →'; button.id = 'daily-clean';
    button.onclick = () => act(async () => showPlan(await api('plan', { ids: [candidate.id] })));
    $('.focus-actions').prepend(button);
  }
  if (focusedId) document.getElementById(focusedId)?.focus({ preventScroll: true });
  updateDailyProgress();
}

function updateDailyProgress() {
  const running = !!state.progress?.running;
  const wasScanning = dailyWasScanning;
  dailyWasScanning = running;
  const host = $('#today');
  if (!host) return;
  if (running && host.dataset.stage !== 'scanning') renderDaily();
  if (!running && wasScanning) {
    renderDaily();
    if (!state.progress.error) { chime(); host.classList.add('scan-landed'); clearTimeout(dailyMotionTimer); dailyMotionTimer = setTimeout(() => host.classList.remove('scan-landed'), 1200); }
  }
  if (running) {
    const p = state.progress;
    if ($('#daily-track')) $('#daily-track').style.width = (p.total ? Math.max(2, p.done / p.total * 100) : 2) + '%';
    if ($('#daily-progress-label')) $('#daily-progress-label').textContent = `${p.message} · ${p.done || 0} / ${p.total || '…'}`;
  }
}

async function finishDaily(decision, id) {
  if (dailyFinishing || busy) return;
  dailyFinishing = true;
  try {
    state.daily = await api('daily-finish', { decision, id });
    renderDaily(); celebrateDaily();
  } catch (e) { notice(e.message, true); }
  finally { dailyFinishing = false; }
}

function celebrateDaily() {
  chime('finish');
  const dialog = $('#daily-celebration');
  dialog.innerHTML = `<div class="celebration-sun"></div><div class="celebration-sparks" aria-hidden="true">${Array.from({ length: 18 }, () => '<i>✦</i>').join('')}</div><img src="/assets/companion.png" width="220" height="220" alt="お手入れを終えた相棒"><span class="celebration-label">TODAY, TAKEN CARE OF.</span><h2>今日のMacに、<br>ひと安心。</h2><p>${state.daily?.current?.decision==='organized'?'確認したデータをゴミ箱へ移動しました。<br>必要なら、履歴から元に戻せます。':state.daily?.current?.decision==='refreshed'?'uvの未使用キャッシュを整理しました。<br>実行結果は履歴で確認できます。':'状態を見て、今日の判断を記録しました。<br>大切なデータは、そのままです。'}</p><div class="earned-stamp">✦ <span>お手入れの足あとが、ひとつ。</span></div><button class="daily-start" id="celebration-close">気持ちよく、おしまい <b>✓</b></button>`;
  dialog.querySelectorAll('.celebration-sparks i').forEach((el, i) => { el.style.setProperty('--angle', `${i * 20}deg`); el.style.setProperty('--delay', `${(i % 4) * .06}s`); el.style.setProperty('--distance', `${100 + i % 5 * 19}px`); });
  $('#celebration-close').onclick = () => { dialog.close(); setView('today'); };
  dialog.showModal();
}

window.addEventListener('studio-organized', event => {
  if (!state.daily?.current?.scan_at || state.daily?.current?.completed_at) return;
  const receipt = event.detail;
  if (receipt.status === 'moved') finishDaily('organized', receipt.id);
  if (receipt.status === 'completed') finishDaily('refreshed', receipt.id);
});

renderDaily();
