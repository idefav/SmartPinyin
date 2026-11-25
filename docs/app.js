(() => {
  'use strict';

  const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* ========================================================================
     1. 主题切换（Dark 默认 / Light 持久化）
     ======================================================================== */
  const htmlEl = document.documentElement;
  const themeToggle = document.getElementById('themeToggle');
  const themeIcon = document.getElementById('themeIcon');

  function applyTheme(theme) {
    htmlEl.setAttribute('data-theme', theme);
    if (themeIcon) {
      themeIcon.textContent = theme === 'dark' ? '☀' : '☾';
    }
    try {
      window.localStorage.setItem('smartpinyin-theme', theme);
    } catch (_) {
      // 忽略无痕模式存储限制
    }
  }

  let initialTheme = 'dark';
  try {
    const saved = window.localStorage.getItem('smartpinyin-theme');
    if (saved === 'light' || saved === 'dark') {
      initialTheme = saved;
    }
  } catch (_) {}
  applyTheme(initialTheme);

  if (themeToggle) {
    themeToggle.addEventListener('click', () => {
      const next = htmlEl.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
      applyTheme(next);
    });
  }

  /* ========================================================================
     2. 工具函数：可取消打字动画与候选 DOM 渲染
     ======================================================================== */
  function createCandNode(item, index) {
    const el = document.createElement('span');
    el.className = 'cand-item' + (index === 0 ? ' selected' : '');
    el.style.animationDelay = `${index * 45}ms`;

    const num = document.createElement('span');
    num.className = 'cand-num';
    num.textContent = String(index + 1);
    el.appendChild(num);

    const text = document.createElement('span');
    text.textContent = item.text;
    el.appendChild(text);

    if (item.badge) {
      const badge = document.createElement('span');
      badge.className = `badge-cap ${item.badgeClass || 'badge-typo'}`;
      badge.textContent = item.badge;
      el.appendChild(badge);
    }
    return el;
  }

  function renderCandidates(container, list) {
    if (!container) return;
    container.replaceChildren(...list.map(createCandNode));
  }

  function sleep(ms, signal) {
    return new Promise((resolve) => {
      if (signal && signal.aborted) {
        resolve(false);
        return;
      }
      const timer = window.setTimeout(() => {
        if (signal) signal.removeEventListener('abort', onAbort);
        resolve(true);
      }, prefersReducedMotion ? 0 : ms);

      function onAbort() {
        window.clearTimeout(timer);
        resolve(false);
      }
      if (signal) signal.addEventListener('abort', onAbort, { once: true });
    });
  }

  async function typeText(el, text, stepMs, signal) {
    if (!el) return false;
    if (prefersReducedMotion) {
      el.textContent = text;
      return !(signal && signal.aborted);
    }
    el.textContent = '';
    for (let i = 1; i <= text.length; i += 1) {
      if (signal && signal.aborted) return false;
      el.textContent = text.slice(0, i);
      const ok = await sleep(stepMs, signal);
      if (!ok) return false;
    }
    return true;
  }

  /* ========================================================================
     3. 顶部滚动进度条 + 环境光晕视差（rAF 节流）
     ======================================================================== */
  const progressBar = document.getElementById('scrollProgressBar');
  const orb1 = document.getElementById('orb1');
  const orb2 = document.getElementById('orb2');
  const orb3 = document.getElementById('orb3');
  const heroParallax = document.getElementById('heroParallax');
  let rafScheduled = false;

  function updateScrollEffects() {
    rafScheduled = false;
    const scrollTop = window.scrollY || window.pageYOffset || 0;
    const maxScroll = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
    const ratio = Math.min(1, Math.max(0, scrollTop / maxScroll));

    if (progressBar) {
      progressBar.style.transform = `scaleX(${ratio.toFixed(4)})`;
    }

    if (!prefersReducedMotion) {
      if (orb1) orb1.style.transform = `translate3d(${ratio * 48}px, ${ratio * 90}px, 0)`;
      if (orb2) orb2.style.transform = `translate3d(${-ratio * 64}px, ${ratio * 120}px, 0)`;
      if (orb3) orb3.style.transform = `translate3d(${ratio * 35}px, ${-ratio * 70}px, 0)`;
      if (heroParallax && scrollTop < 800) {
        const y = scrollTop * 0.055;
        heroParallax.style.transform = `translate3d(0, ${y.toFixed(1)}px, 0)`;
      }
    }
  }

  window.addEventListener('scroll', () => {
    if (!rafScheduled) {
      rafScheduled = true;
      window.requestAnimationFrame(updateScrollEffects);
    }
  }, { passive: true });
  updateScrollEffects();

  /* ========================================================================
     4. Hero 自动循环实时演示（可点击切换）
     ======================================================================== */
  const HERO_DEMOS = [
    {
      tag: '演示 1/5 · 三级快打自动纠错',
      latency: 'L1 0.58 ms',
      mode: '中文',
      scene: '拼 · 自动纠偏',
      committed: '周末去',
      preedit: 'shaighai',
      pinyin: 's hai g hai  →  shang hai',
      candidates: [
        { text: '上海', badge: '纠', badgeClass: 'badge-typo' },
        { text: '上海滩' },
        { text: '伤害' },
        { text: '晒干' }
      ],
      finalCommit: '周末去上海',
      predict: null,
      translate: null
    },
    {
      tag: '演示 2/5 · 中英文免切混输与英文纠错',
      latency: '73K EN · 0.62 ms',
      mode: '中英',
      scene: '拼 · 中英混输',
      committed: '发我一下',
      preedit: 'gitdiz',
      pinyin: 'git + di zhi',
      candidates: [
        { text: 'git地址', badge: '混', badgeClass: 'badge-mixed' },
        { text: 'git地址栏', badge: '混', badgeClass: 'badge-mixed' },
        { text: 'git', badge: '英', badgeClass: 'badge-mixed' },
        { text: '给她的' }
      ],
      finalCommit: '发我一下git地址',
      predict: null,
      translate: null
    },
    {
      tag: '演示 3/5 · 整句暂存两段空格自动校对',
      latency: 'L1+L2 五重护栏',
      mode: '校对',
      scene: '草稿 · 再按空格上屏',
      committed: '',
      preedit: '我门昨天部暑了新版本',
      pinyin: '草稿自动纠偏  ·  ⇧↩ 保留原稿',
      candidates: [
        { text: '我们昨天部署了新版本', badge: '纠', badgeClass: 'badge-typo' },
        { text: '我门昨天部暑了新版本（原稿）' }
      ],
      finalCommit: '我们昨天部署了新版本',
      predict: null,
      translate: null
    },
    {
      tag: '演示 4/5 · 诗词与成语微胶囊',
      latency: 'Tag 0.015 ms',
      mode: '中文',
      scene: '拼 · 诗词',
      committed: '',
      preedit: 'chrdw',
      pinyin: 'ch r d w',
      candidates: [
        { text: '锄禾日当午', badge: '诗', badgeClass: 'badge-poetry' },
        { text: '超然度外', badge: '成', badgeClass: 'badge-idiom' },
        { text: '成人读物' },
        { text: '插入的' }
      ],
      finalCommit: '锄禾日当午',
      predict: null,
      translate: null
    },
    {
      tag: '演示 5/5 · 100% 离线实时翻译上屏',
      latency: 'XPC HY-MT 1.8B',
      mode: '译 → EN',
      scene: '译 · EN',
      committed: '',
      preedit: '今天天气真不错',
      pinyin: 'jin tian tian qi zhen bu cuo',
      candidates: [
        { text: '今天天气真不错' },
        { text: '今天天气' }
      ],
      finalCommit: 'The weather is really nice today.',
      predict: null,
      translate: { lang: 'EN', text: 'The weather is really nice today.' }
    }
  ];

  const heroDemoTag = document.getElementById('heroDemoTag');
  const heroLatency = document.getElementById('heroLatency');
  const heroModeLabel = document.getElementById('heroModeLabel');
  const heroCommitted = document.getElementById('heroCommitted');
  const heroPreedit = document.getElementById('heroPreedit');
  const heroHud = document.getElementById('heroHud');
  const heroHudPinyin = document.getElementById('heroHudPinyin');
  const heroSceneChip = document.getElementById('heroSceneChip');
  const heroCandidates = document.getElementById('heroCandidates');
  const heroTranslateRow = document.getElementById('heroTranslateRow');
  const heroTransLang = document.getElementById('heroTransLang');
  const heroTransText = document.getElementById('heroTransText');
  const heroPredictStrip = document.getElementById('heroPredictStrip');
  const heroPredictItems = document.getElementById('heroPredictItems');
  const heroDotButtons = Array.from(document.querySelectorAll('#heroDemoDots .demo-dot'));

  let heroAbort = null;
  let heroIndex = 0;

  function setActiveHeroDot(idx) {
    heroDotButtons.forEach((btn, i) => btn.classList.toggle('active', i === idx));
  }

  async function runHeroDemo(idx, loop = true) {
    if (heroAbort) heroAbort.abort();
    heroAbort = new AbortController();
    const { signal } = heroAbort;
    heroIndex = idx;
    setActiveHeroDot(idx);

    const d = HERO_DEMOS[idx];
    if (heroDemoTag) heroDemoTag.textContent = d.tag;
    if (heroLatency) heroLatency.textContent = d.latency;
    if (heroModeLabel) heroModeLabel.textContent = d.mode;
    if (heroSceneChip) {
      heroSceneChip.textContent = d.scene;
      heroSceneChip.classList.toggle('trans-chip', Boolean(d.translate));
    }

    if (heroCommitted) heroCommitted.textContent = d.committed;
    if (heroPreedit) heroPreedit.textContent = '';
    if (heroTranslateRow) heroTranslateRow.classList.add('hidden');
    if (heroPredictStrip) heroPredictStrip.classList.add('hidden');

    if (d.candidates) {
      if (heroHud) heroHud.classList.remove('hidden');
      if (heroHudPinyin) heroHudPinyin.textContent = '';
      if (heroCandidates) heroCandidates.replaceChildren();

      const ok = await typeText(heroPreedit, d.preedit, 70, signal);
      if (!ok) return;

      if (heroHudPinyin) heroHudPinyin.textContent = d.pinyin;
      renderCandidates(heroCandidates, d.candidates);

      if (d.translate && heroTranslateRow) {
        heroTranslateRow.classList.remove('hidden');
        if (heroTransLang) heroTransLang.textContent = d.translate.lang;
        const ok2 = await typeText(heroTransText, d.translate.text, 26, signal);
        if (!ok2) return;
      }

      if (!(await sleep(1450, signal))) return;
      if (heroCommitted) heroCommitted.textContent = d.finalCommit;
      if (heroPreedit) heroPreedit.textContent = '';
    } else if (d.predict) {
      if (heroHud) heroHud.classList.add('hidden');
      if (!(await typeText(heroCommitted, d.committed, 95, signal))) return;
      if (heroPredictStrip && heroPredictItems) {
        heroPredictItems.replaceChildren(
          ...d.predict.map((label, i) => {
            const sp = document.createElement('span');
            sp.className = 'predict-pill' + (i === 0 ? ' active' : '');
            sp.textContent = label;
            return sp;
          })
        );
        heroPredictStrip.classList.remove('hidden');
      }
      if (!(await sleep(1250, signal))) return;
      if (heroCommitted) heroCommitted.textContent = d.finalCommit;
      if (heroPredictStrip) heroPredictStrip.classList.add('hidden');
    }

    if (loop && !(await sleep(1600, signal))) return;
    if (loop && !signal.aborted) {
      runHeroDemo((idx + 1) % HERO_DEMOS.length, true);
    }
  }

  heroDotButtons.forEach((btn) => {
    btn.addEventListener('click', () => {
      const next = Number(btn.dataset.demo || 0);
      runHeroDemo(next, true);
    });
  });

  runHeroDemo(0, true);

  /* ========================================================================
     5. Sticky Scrollytelling 五大章节交互动画控制器
     ======================================================================== */
  const STORY_TITLES = [
    'SmartPinyin · 中英三级快打自动纠错',
    'SmartPinyin · 诗词/成语与 0ms 场景适配',
    'SmartPinyin · 中英混输、整句校对与联想',
    'SmartPinyin · XPC 离线翻译 (< 2GB)',
    'SmartPinyin · 开源词库中心与防损自卸载'
  ];

  const TYPO_PRESETS = {
    shaighai: {
      typed: 'shaighai',
      seg: 's hai g hai  →  shang hai',
      raw: 'shaighai',
      fixed: 'shanghai',
      writeback: '上海 (shanghai)',
      latency: 'Shadow Probe · 0.61 ms',
      cands: [
        { text: '上海', badge: '纠', badgeClass: 'badge-typo' },
        { text: '上海归海' },
        { text: '晒干后' },
        { text: '上海工' }
      ]
    },
    shanhai: {
      typed: 'shanhai',
      seg: 'shan hai  (前后鼻音智能双路)',
      raw: 'shanhai',
      fixed: 'shanghai',
      writeback: '上海 (shanghai)',
      latency: 'Nasal Fuzzy · 0.49 ms',
      cands: [
        { text: '山海' },
        { text: '上海', badge: '纠', badgeClass: 'badge-typo' },
        { text: '山海经' },
        { text: '善待' }
      ]
    },
    dokcer: {
      typed: 'dokcer',
      seg: 'dokcer  →  Docker (QWERTY 转置纠偏)',
      raw: 'dokcer',
      fixed: 'Docker',
      writeback: 'Docker (en-spell)',
      latency: 'EN Two-Tier · 0.42 ms',
      cands: [
        { text: 'Docker', badge: '纠', badgeClass: 'badge-typo' },
        { text: 'dokcer', badge: '英', badgeClass: 'badge-mixed' },
        { text: 'docker', badge: '英', badgeClass: 'badge-mixed' }
      ]
    },
    gtidiz: {
      typed: 'gtidiz',
      seg: 'gti → git  +  di zhi',
      raw: 'gtidiz',
      fixed: 'git + dizhi',
      writeback: 'git地址 (bilingual)',
      latency: 'Bilingual Fix · 0.58 ms',
      cands: [
        { text: 'git地址', badge: '纠', badgeClass: 'badge-typo' },
        { text: 'git地址栏', badge: '混', badgeClass: 'badge-mixed' },
        { text: '改天的' }
      ]
    }
  };

  const SCENE_PRESETS = {
    poetry: {
      app: '备忘录 · 古诗词赏析',
      context: '唐诗三百首默写：',
      typed: 'ch r d w',
      seg: 'ch r d w',
      badge: '拼 · 诗词',
      boost: '+1.20 诗词提权',
      pct: '92%',
      cands: [
        { text: '锄禾日当午', badge: '诗', badgeClass: 'badge-poetry' },
        { text: '超然度外', badge: '成', badgeClass: 'badge-idiom' },
        { text: '成人读物' },
        { text: '插入的' }
      ]
    },
    idiom: {
      app: 'Pages · 文学写作',
      context: '面对复杂系统设计，他早已',
      typed: 'x y ch zh',
      seg: 'x y ch zh',
      badge: '拼 · 文学',
      boost: '+1.08 成语提权',
      pct: '88%',
      cands: [
        { text: '胸有成竹', badge: '成', badgeClass: 'badge-idiom' },
        { text: '信用充值' },
        { text: '需要称重' },
        { text: '行业成长' }
      ]
    },
    gaming: {
      app: 'Discord · 游戏语音群',
      context: '刚打完副本，主 C 装备堆满',
      typed: 'bao ji',
      seg: 'bao ji',
      badge: '拼 · 游戏',
      boost: '+1.35 游戏词库',
      pct: '95%',
      cands: [
        { text: '暴击', badge: '游', badgeClass: 'badge-domain' },
        { text: '暴击伤害', badge: '游', badgeClass: 'badge-domain' },
        { text: '宝鸡' },
        { text: '包机' }
      ]
    },
    math: {
      app: 'Typora · 论文公式推导',
      context: '对周期函数做离散',
      typed: 'fu li ye',
      seg: 'fu li ye',
      badge: '拼 · 数学',
      boost: '+1.40 数学词库',
      pct: '96%',
      cands: [
        { text: '傅里叶变换', badge: '数', badgeClass: 'badge-domain' },
        { text: '傅里叶级数', badge: '数', badgeClass: 'badge-domain' },
        { text: '福利业' },
        { text: '附丽也' }
      ]
    },
    art: {
      app: 'Figma · 界面视觉稿',
      context: '调整锚点手柄平滑这段',
      typed: 'bei sai er',
      seg: 'bei sai er',
      badge: '拼 · 美术',
      boost: '+1.30 美术设计',
      pct: '91%',
      cands: [
        { text: '贝塞尔曲线', badge: '艺', badgeClass: 'badge-domain' },
        { text: '贝塞尔', badge: '艺', badgeClass: 'badge-domain' },
        { text: '被塞而' }
      ]
    },
    code: {
      app: 'Xcode · Swift 源码注释',
      context: '避免主线程阻塞，改用异步',
      typed: 'xie cheng',
      seg: 'xie cheng',
      badge: '拼 · Code',
      boost: '+1.38 计算机词库',
      pct: '94%',
      cands: [
        { text: '协程', badge: '码', badgeClass: 'badge-domain' },
        { text: '携程' },
        { text: '写成' },
        { text: '协成' }
      ]
    }
  };

  const TRANS_PRESETS = {
    EN: {
      zh: '今天晚上有空一起吃晚饭吗？',
      out: 'Are you free to have dinner together tonight?',
      ramText: '1.45 GB / 2.00 GB',
      ramPct: '69%',
      slot: 'HY-MT1.5-1.8B（英语翻译槽活跃）'
    },
    JA: {
      zh: '今天晚上有空一起吃晚饭吗？',
      out: '今夜一緒に晩ご飯を食べませんか？',
      ramText: '1.46 GB / 2.00 GB',
      ramPct: '70%',
      slot: 'HY-MT1.5-1.8B（日语翻译槽活跃）'
    },
    KO: {
      zh: '今天晚上有空一起吃晚饭吗？',
      out: '오늘 저녁에 같이 식사할 시간 있나요?',
      ramText: '1.44 GB / 2.00 GB',
      ramPct: '68%',
      slot: 'HY-MT1.5-1.8B（韩语翻译槽活跃）'
    },
    FR: {
      zh: '今天晚上有空一起吃晚饭吗？',
      out: 'Es-tu libre pour dîner ensemble ce soir ?',
      ramText: '1.45 GB / 2.00 GB',
      ramPct: '69%',
      slot: 'HY-MT1.5-1.8B（法语翻译槽活跃）'
    }
  };

  const storySteps = Array.from(document.querySelectorAll('.story-step'));
  const stagePanels = Array.from(document.querySelectorAll('.stage-panel'));
  const stageWindowTitle = document.getElementById('stageWindowTitle');
  const stageStepIndicator = document.getElementById('stageStepIndicator');

  let currentStep = -1;
  let stageAbort = null;
  let activeTypoKey = 'shaighai';
  let activeSceneKey = 'poetry';
  let activeCtxMode = 'mixed';
  let activeLangKey = 'EN';
  let activeLifeMode = 'lexicon';

  async function playStepAnimation(stepIndex) {
    if (stageAbort) stageAbort.abort();
    stageAbort = new AbortController();
    const { signal } = stageAbort;

    if (stepIndex === 0) {
      const p = TYPO_PRESETS[activeTypoKey];
      const typoTyped = document.getElementById('typoTyped');
      const typoSeg = document.getElementById('typoSeg');
      const typoCandidates = document.getElementById('typoCandidates');
      const typoLatency = document.getElementById('typoLatency');
      const typoRaw = document.getElementById('typoRawCode');
      const typoFixed = document.getElementById('typoFixedCode');
      const typoWriteback = document.getElementById('typoWriteback');

      if (typoLatency) typoLatency.textContent = p.latency;
      if (typoRaw) typoRaw.textContent = p.raw;
      if (typoFixed) typoFixed.textContent = p.fixed;
      if (typoWriteback) typoWriteback.textContent = p.writeback;
      if (typoSeg) typoSeg.textContent = '';
      if (typoCandidates) typoCandidates.replaceChildren();

      const ok = await typeText(typoTyped, p.typed, 65, signal);
      if (!ok) return;
      if (typoSeg) typoSeg.textContent = p.seg;
      renderCandidates(typoCandidates, p.cands);
      return;
    }

    if (stepIndex === 1) {
      const s = SCENE_PRESETS[activeSceneKey];
      const appPill = document.getElementById('sceneAppPill');
      const ctxBar = document.getElementById('sceneContextBar');
      const typedEl = document.getElementById('sceneTyped');
      const segEl = document.getElementById('sceneSeg');
      const badgeEl = document.getElementById('sceneBadgePill');
      const candEl = document.getElementById('sceneCandidates');
      const boostVal = document.getElementById('sceneBoostVal');
      const boostBar = document.getElementById('sceneBoostBar');

      if (appPill) appPill.textContent = s.app;
      if (ctxBar) ctxBar.innerHTML = `前文语境：<span>${s.context}</span>`;
      if (badgeEl) badgeEl.textContent = s.badge;
      if (boostVal) boostVal.textContent = s.boost;
      if (boostBar) boostBar.style.width = '0%';
      if (candEl) candEl.replaceChildren();

      const ok = await typeText(typedEl, s.typed, 55, signal);
      if (!ok) return;
      if (segEl) segEl.textContent = s.seg;
      renderCandidates(candEl, s.cands);
      if (boostBar) {
        window.requestAnimationFrame(() => {
          if (!signal.aborted) boostBar.style.width = s.pct;
        });
      }
      return;
    }

    if (stepIndex === 2) {
      const appPill = document.getElementById('ctxAppPill');
      const latPill = document.getElementById('ctxLatencyPill');
      const committed = document.getElementById('ctxCommitted');
      const preedit = document.getElementById('ctxPreedit');
      const ctxHud = document.getElementById('ctxHud');
      const ctxHudPinyin = document.getElementById('ctxHudPinyin');
      const ctxSceneChip = document.getElementById('ctxSceneChip');
      const ctxCandidates = document.getElementById('ctxCandidates');
      const predictStrip = document.getElementById('ctxPredictStrip');
      const predictItems = document.getElementById('ctxPredictItems');
      const mixedCard = document.getElementById('ctxMixedCard');

      if (activeCtxMode === 'mixed') {
        if (appPill) appPill.textContent = 'VS Code · 中英免切混输';
        if (latPill) latPill.textContent = '73K 英文词库 · 0.55 ms';
        if (predictStrip) predictStrip.classList.add('hidden');
        if (mixedCard) mixedCard.classList.remove('hidden');
        if (ctxHud) ctxHud.classList.remove('hidden');
        if (ctxHudPinyin) ctxHudPinyin.textContent = '';
        if (ctxSceneChip) ctxSceneChip.textContent = '拼 · 中英混输';
        if (ctxCandidates) ctxCandidates.replaceChildren();
        if (committed) committed.textContent = '请发一下 ';
        if (preedit) preedit.textContent = '';

        const ok = await typeText(preedit, 'reactzj', 65, signal);
        if (!ok) return;
        if (ctxHudPinyin) ctxHudPinyin.textContent = 'React + zu jian';
        renderCandidates(ctxCandidates, [
          { text: 'React组件', badge: '混', badgeClass: 'badge-mixed' },
          { text: 'React总结', badge: '混', badgeClass: 'badge-mixed' },
          { text: 'React', badge: '英', badgeClass: 'badge-mixed' },
          { text: 'react', badge: '英', badgeClass: 'badge-mixed' }
        ]);
      } else if (activeCtxMode === 'draft') {
        if (appPill) appPill.textContent = '飞书 · 整句暂存校对（⌃⌥D）';
        if (latPill) latPill.textContent = '两段空格 · L1+L2 五重护栏';
        if (predictStrip) predictStrip.classList.add('hidden');
        if (mixedCard) mixedCard.classList.add('hidden');
        if (ctxHud) ctxHud.classList.remove('hidden');
        if (ctxHudPinyin) ctxHudPinyin.textContent = '';
        if (ctxSceneChip) ctxSceneChip.textContent = '草稿 · 再按空格上屏';
        if (ctxCandidates) ctxCandidates.replaceChildren();
        if (committed) committed.textContent = '';
        if (preedit) preedit.textContent = '';

        const ok = await typeText(preedit, '我门昨天部暑了新版本', 55, signal);
        if (!ok) return;
        if (ctxHudPinyin) ctxHudPinyin.textContent = '自动纠偏完成 · ⇧↩ 保留原稿 · ⌥⌫ 整段撤回';
        renderCandidates(ctxCandidates, [
          { text: '我们昨天部署了新版本', badge: '纠', badgeClass: 'badge-typo' },
          { text: '我门昨天部暑了新版本（原稿）' }
        ]);
      } else {
        if (appPill) appPill.textContent = '微信 · 对话窗口';
        if (latPill) latPill.textContent = 'Session Memory · 0ms 去重';
        if (ctxHud) ctxHud.classList.add('hidden');
        if (mixedCard) mixedCard.classList.add('hidden');
        if (predictStrip) predictStrip.classList.add('hidden');
        if (preedit) preedit.textContent = '';

        const ok = await typeText(committed, '明天带家人去上海植物园', 65, signal);
        if (!ok) return;
        if (predictItems && predictStrip) {
          predictItems.replaceChildren(
            ...['1 逛逛', '2 看郁金香', '3 拍照打卡'].map((txt, i) => {
              const sp = document.createElement('span');
              sp.className = 'predict-pill' + (i === 0 ? ' active' : '');
              sp.textContent = txt;
              return sp;
            })
          );
          predictStrip.classList.remove('hidden');
        }
      }
      return;
    }

    if (stepIndex === 3) {
      const t = TRANS_PRESETS[activeLangKey];
      const zhEl = document.getElementById('transZhSource');
      const badgeEl = document.getElementById('transModeBadge');
      const langEl = document.getElementById('stageTransLang');
      const outEl = document.getElementById('stageTransOutput');
      const ramBar = document.getElementById('ramXpcBar');
      const ramTotal = document.getElementById('ramTotalLabel');
      const ramSlot = document.getElementById('ramSlotLabel');
      const pills = document.querySelectorAll('#stageLangStrip .lang-pill');

      pills.forEach((p) => p.classList.toggle('active', p.dataset.lp === activeLangKey));
      if (badgeEl) badgeEl.textContent = `译 → ${activeLangKey}`;
      if (langEl) langEl.textContent = activeLangKey;
      if (outEl) outEl.textContent = '';
      if (ramBar) ramBar.style.width = '22%';
      if (ramTotal) ramTotal.textContent = '0.48 GB / 2.00 GB';

      const ok1 = await typeText(zhEl, t.zh, 48, signal);
      if (!ok1) return;

      if (ramBar) ramBar.style.width = t.ramPct;
      if (ramTotal) ramTotal.textContent = t.ramText;
      if (ramSlot) ramSlot.innerHTML = `<i class="swatch xpc"></i>${t.slot}`;

      await typeText(outEl, t.out, 22, signal);
      return;
    }

    if (stepIndex === 4) {
      const appPill = document.getElementById('lifeAppPill');
      const statusPill = document.getElementById('lifeStatusPill');
      const lexView = document.getElementById('lifeLexiconView');
      const unView = document.getElementById('lifeUninstallView');

      if (activeLifeMode === 'lexicon') {
        if (appPill) appPill.textContent = 'SmartPinyin Setup · 词库与场景';
        if (statusPill) statusPill.textContent = '后台热重载就绪';
        if (lexView) lexView.classList.remove('hidden');
        if (unView) unView.classList.add('hidden');
      } else {
        if (appPill) appPill.textContent = 'SmartPinyin Setup · 卸载自己';
        if (statusPill) statusPill.textContent = '白名单安全校验通过';
        if (lexView) lexView.classList.add('hidden');
        if (unView) unView.classList.remove('hidden');
      }
    }
  }

  function activateStep(stepIndex) {
    if (stepIndex === currentStep) return;
    currentStep = stepIndex;

    storySteps.forEach((el, idx) => el.classList.toggle('active', idx === stepIndex));
    stagePanels.forEach((panel, idx) => panel.classList.toggle('active', idx === stepIndex));

    if (stageWindowTitle) stageWindowTitle.textContent = STORY_TITLES[stepIndex] || 'SmartPinyin';
    if (stageStepIndicator) stageStepIndicator.textContent = `0${stepIndex + 1} / 05`;

    playStepAnimation(stepIndex);
  }

  // 使用 IntersectionObserver 监听用户滚动经过每个章节
  if ('IntersectionObserver' in window) {
    const stepObserver = new IntersectionObserver(
      (entries) => {
        let bestEntry = null;
        for (const entry of entries) {
          if (entry.isIntersecting) {
            if (!bestEntry || entry.intersectionRatio > bestEntry.intersectionRatio) {
              bestEntry = entry;
            }
          }
        }
        if (bestEntry) {
          const idx = Number(bestEntry.target.dataset.step || 0);
          activateStep(idx);
        }
      },
      {
        rootMargin: '-30% 0px -42% 0px',
        threshold: [0.1, 0.35, 0.6]
      }
    );
    storySteps.forEach((el) => stepObserver.observe(el));
  }

  // 点击左侧章节卡片也可直接激活对应动画
  storySteps.forEach((el) => {
    el.addEventListener('click', (e) => {
      if (e.target.closest('button')) return;
      activateStep(Number(el.dataset.step || 0));
    });
  });

  // 绑定章节内交互子控件按钮
  document.querySelectorAll('.step-controls').forEach((group) => {
    group.addEventListener('click', (e) => {
      const btn = e.target.closest('button.chip-btn');
      if (!btn) return;
      group.querySelectorAll('button.chip-btn').forEach((b) => b.classList.remove('active'));
      btn.classList.add('active');

      const kind = group.dataset.control;
      if (kind === 'typo') {
        activeTypoKey = btn.dataset.typo || 'shaighai';
        currentStep = -1;
        activateStep(0);
      } else if (kind === 'scene') {
        activeSceneKey = btn.dataset.scene || 'poetry';
        currentStep = -1;
        activateStep(1);
      } else if (kind === 'context') {
        activeCtxMode = btn.dataset.ctx || 'predict';
        currentStep = -1;
        activateStep(2);
      } else if (kind === 'translate') {
        activeLangKey = btn.dataset.lang || 'EN';
        currentStep = -1;
        activateStep(3);
      } else if (kind === 'lifecycle') {
        activeLifeMode = btn.dataset.life || 'lexicon';
        currentStep = -1;
        activateStep(4);
      }
    });
  });

  activateStep(0);

  /* ========================================================================
     6. 滚动触发显现 ([data-reveal]) 与数字滚动递增动画 (.counter)
     ======================================================================== */
  function animateCounter(el) {
    if (el.dataset.animated === '1') return;
    el.dataset.animated = '1';
    const target = Number(el.dataset.target || 0);
    const decimals = Number(el.dataset.decimals || 0);

    if (prefersReducedMotion) {
      el.textContent = decimals > 0 ? target.toFixed(decimals) : Math.round(target).toLocaleString('en-US');
      return;
    }

    const duration = 1050;
    const start = performance.now();

    function tick(now) {
      const t = Math.min(1, (now - start) / duration);
      // easeOutExpo
      const eased = t === 1 ? 1 : 1 - Math.pow(2, -10 * t);
      const val = target * eased;
      el.textContent = decimals > 0 ? val.toFixed(decimals) : Math.round(val).toLocaleString('en-US');
      if (t < 1) {
        window.requestAnimationFrame(tick);
      }
    }
    window.requestAnimationFrame(tick);
  }

  const revealNodes = document.querySelectorAll('[data-reveal]');
  if ('IntersectionObserver' in window) {
    const revealObserver = new IntersectionObserver(
      (entries, obs) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          entry.target.classList.add('revealed');
          entry.target.querySelectorAll('.counter').forEach(animateCounter);
          obs.unobserve(entry.target);
        }
      },
      { threshold: 0.14, rootMargin: '0px 0px -40px 0px' }
    );
    revealNodes.forEach((n) => revealObserver.observe(n));
  } else {
    revealNodes.forEach((n) => {
      n.classList.add('revealed');
      n.querySelectorAll('.counter').forEach(animateCounter);
    });
  }
})();
