/*
 * window.aiostreamsApp, the bridge AIOStreams' own apps give its web app
 * (protocol 2, as packages/android/bridge/AppBridge.kt injects it). The page
 * then lays itself out for a TV and plays through the app's player.
 *
 * The app fills in __VERSION__, __DEVICE__ and __DEVICE_ID__ as JSON strings, and
 * the storage placeholder with its copy of the page's localStorage.
 */
(() => {
  if (window.top !== window || window.aiostreamsApp) return;
  const handler = window.webkit?.messageHandlers?.aiostreamsNative;
  if (!handler) return;

  /*
   * Artwork otherwise goes through workers that shrink it on OffscreenCanvas
   * and hand back blob URLs, which tvOS's WebKit shows as broken images.
   * Without OffscreenCanvas the page loads each picture as a plain <img>.
   */
  try {
    delete window.OffscreenCanvas;
  } catch {}
  /*
   * The page sizes artwork for a TV at up to twice its 1280-wide layout,
   * which on an Apple TV 4K is twice what a 1080p picture shows and, decoded,
   * what runs the page out of memory scrolling fast. At most 1.5 times, as a
   * 1080p screen draws it, through the screen width the page reads it from.
   */
  try {
    const width = Object.getOwnPropertyDescriptor(Screen.prototype, 'width');
    const MAX_RATIO = 1.5;
    Object.defineProperty(Screen.prototype, 'width', {
      configurable: true,
      get() {
        const real = width.get.call(this);
        const dppx = window.devicePixelRatio || 1;
        const cap = (innerWidth * MAX_RATIO) / dppx;
        return innerWidth && real > cap ? Math.round(cap) : real;
      },
    });
  } catch {}

  /*
   * The page's saved copies of artwork come back as blob URLs too (its
   * Settings → Storage → Artwork), which showed as "?" logos and avatars.
   * Off, every picture loads straight from its address.
   */
  try {
    localStorage.setItem('aiostreams-web-cache-artwork', 'false');
  } catch {}

  /*
   * The page's half of the app's diagnostics (AIODiagnostics): the keys as
   * the app sends them and whether the page took them, focus, clicks, the
   * bridge's messages and errors. The app hands it out with its own log.
   */
  const DIAG_MAX = 3000;
  const diagLines = [];
  let diagSeq = 0;
  const pad = (n, width = 2) => String(n).padStart(width, '0');
  const diag = (kind, text) => {
    const d = new Date();
    const at = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(), 3)}`;
    diagLines.push(`#${++diagSeq} ${at} [${kind}] ${String(text).slice(0, 500)}`);
    if (diagLines.length > DIAG_MAX) diagLines.splice(0, diagLines.length - DIAG_MAX);
  };
  /** An element as a line of the log: tag, id, first classes, its role and state, and its words. */
  const describe = (el) => {
    if (!(el instanceof Element)) return el === document ? 'document' : String(el);
    let text = el.tagName.toLowerCase();
    if (el.id) text += `#${el.id}`;
    const classes = [...el.classList].slice(0, 2);
    if (classes.length) text += `.${classes.join('.')}`;
    for (const name of ['role', 'data-ui', 'data-name', 'aria-checked', 'aria-expanded', 'data-state', 'type']) {
      const value = el.getAttribute(name);
      if (value !== null) text += `[${name}=${value}]`;
    }
    const words = (el.getAttribute('aria-label') || el.textContent || '').trim().replace(/\s+/g, ' ');
    return words ? `${text} "${words.slice(0, 40)}"` : text;
  };
  /** A message as a line: its type and its smaller fields. */
  const brief = (message) => {
    const fields = {};
    for (const [key, value] of Object.entries(message || {})) {
      if (key === 'type' || key === 'headers') continue;
      fields[key] = typeof value === 'string' && value.length > 120 ? `${value.slice(0, 120)}…` : value;
    }
    const json = JSON.stringify(fields);
    return `${message?.type} ${json.length > 300 ? `${json.slice(0, 300)}…` : json}`;
  };
  /** Sent too often to log one by one. */
  const NOISY = new Set(['tvos-storage', 'player-thumbnail', 'player-subtitle-lines']);
  /** A player's state, without what changes as it plays, to log only what else changed. */
  let lastState = '';
  const stateChange = (message) => {
    const kept = {};
    for (const [key, value] of Object.entries(message)) {
      if (!/position|buffer|cache|time|speed|rate|fps|bitrate|demux/i.test(key)) kept[key] = value;
    }
    const json = JSON.stringify(kept);
    if (json === lastState) return null;
    lastState = json;
    return json;
  };
  /** Key events the bridge dispatched itself, which the window's listeners below leave to key(). */
  const ours = new WeakSet();
  for (const type of ['keydown', 'keyup']) {
    addEventListener(
      type,
      (e) => {
        if (!ours.has(e)) diag('page-key', `${type} ${e.key} on ${describe(e.target)}${e.isTrusted ? '' : ' (page)'}`);
      },
      true
    );
  }
  addEventListener('click', (e) => diag('click', `${describe(e.target)}${e.isTrusted ? '' : ' (page)'}`), true);
  addEventListener('focusin', (e) => diag('focus', describe(e.target)), true);
  addEventListener('blur', (e) => e.target === window && diag('window', 'blur'));
  addEventListener('focus', (e) => e.target === window && diag('window', 'focus'));
  document.addEventListener('visibilitychange', () => diag('window', document.visibilityState));
  /*
   * On a TV the page mounts a row, and starts its artwork, only within 600px
   * of the screen: hooks/use-in-view.ts measures by hand against
   * new DOMRect(0, 0, innerWidth, innerHeight), so artwork still loading as
   * focus arrives fades in under it. That screen is made a screen taller each
   * way, so the rows ahead are ready first. It leans on how the page builds
   * that rect, so it can be turned off in the app menu (Look-ahead).
   */
  let lookAhead = true;
  try {
    lookAhead = localStorage.getItem('tvos-look-ahead') !== 'off';
  } catch {}
  if (lookAhead) {
    try {
      window.DOMRect = new Proxy(window.DOMRect, {
        construct(type, args, newTarget) {
          const [x, y, w, h] = args;
          if (args.length === 4 && x === 0 && y === 0 && w === innerWidth && h === innerHeight)
            args = [0, -h, w, h * 3];
          return Reflect.construct(type, args, newTarget);
        },
      });
    } catch {}
  }
  diag('input', `look-ahead ${lookAhead ? 'on' : 'off'}`);

  /*
   * Artwork that finishes loading where it can be seen fades in in view. The
   * log names each one that did, with how long it took, and sums up every few
   * seconds, to tell a late start (rows mounted near the screen) from a slow
   * server.
   */
  const art = { loaded: 0, seen: 0, waits: [] };
  document.addEventListener(
    'load',
    (e) => {
      const img = e.target;
      if (!(img instanceof HTMLImageElement) || img.getAttribute('data-ui') !== 'artwork') return;
      const src = img.currentSrc || img.src;
      if (!src || src.startsWith('data:')) return;
      art.loaded++;
      const r = img.getBoundingClientRect();
      if (!(r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth)) return;
      art.seen++;
      const timing = performance.getEntriesByName(src).pop();
      const ms = timing ? Math.round(timing.duration) : -1;
      art.waits.push(ms);
      const kb = timing?.transferSize ? `, ${Math.round(timing.transferSize / 1024)} KB` : '';
      diag('artwork', `arrived in view: ${ms < 0 ? '?' : ms} ms to load${kb}, at y ${Math.round(r.top)}`);
    },
    true
  );
  setInterval(() => {
    if (!art.loaded) return;
    const waits = art.waits.filter((ms) => ms >= 0).sort((a, b) => a - b);
    const times = waits.length ? `, median ${waits[waits.length >> 1]} ms, slowest ${waits[waits.length - 1]} ms` : '';
    diag('artwork', `${art.loaded} loaded, ${art.seen} of them in view${times}`);
    art.loaded = art.seen = 0;
    art.waits = [];
  }, 5000);

  addEventListener('gamepadconnected', (e) => diag('input', `gamepad connected: ${e.gamepad?.id} (${e.gamepad?.mapping || 'no mapping'})`));
  addEventListener('unhandledrejection', (e) => diag('error', `unhandled rejection: ${e.reason?.stack || e.reason}`));
  for (const level of ['error', 'warn']) {
    const original = console[level];
    console[level] = function (...args) {
      try {
        diag(`console.${level}`, args.map((a) => (a instanceof Error ? a.stack || a.message : typeof a === 'string' ? a : JSON.stringify(a))).join(' '));
      } catch {}
      return original.apply(this, args);
    };
  }

  const listeners = new Set();
  /** Whether the page's player is open, from what the page tells the app. */
  let inPlayer = false;
  /** A file is loaded, in the player or in a box. */
  let playing = false;
  /** A skip-segment press waiting for its seek to land; see playerKey. */
  let skipped = null;
  /** The video is in a box of the page (a trailer on Home or a title's page), not the player. */
  let framed = false;
  const send = (message) => {
    if (message?.type === 'player-load') inPlayer = !framed;
    else if (message?.type === 'player-stop') inPlayer = false;
    else if (message?.type === 'player-frame') {
      framed = !!message.frame;
      // A trailer opened whole is the player; back in its box, the remote is the page's again.
      inPlayer = !framed && playing;
      // The page sends the box already multiplied by its zoom (it lays out 1280 wide
      // on a TV); the app scales by whatever of the screen's width that leaves.
      message = { ...message, viewport: innerWidth * (window.visualViewport?.scale ?? 1) };
    }
    if (message?.type === 'player-load') playing = true;
    else if (message?.type === 'player-stop') playing = false;
    // Under the player nothing of the page shows; back out of it, its pictures return.
    if (message?.type === 'player-load' || message?.type === 'player-stop')
      setTimeout(() => window.__aioTV && soonSweep(), 600);
    if (message?.type === 'player-seek' && skipped && skipped.toMs == null)
      skipped.toMs = Number(message.positionMs);
    if (!NOISY.has(message?.type)) diag('to-app', brief(message));
    handler.postMessage(JSON.stringify(message));
  };

  /*
   * Reopened where it was left (a saved route, or a reload after WebKit's
   * process ended), the page would have no history before it, and Back would
   * leave the app. Home goes beneath it first, as the router would have
   * recorded it (TanStack's history state), so Back goes there.
   */
  try {
    const hash = location.hash;
    const path = hash.slice(1).split('?')[0] || '/';
    if (path !== '/' && history.length === 1 && history.state?.__TSR_index == null) {
      const key = () => Math.random().toString(36).slice(2, 10);
      const base = location.href.split('#')[0];
      const home = key();
      const here = key();
      history.replaceState({ __TSR_index: 0, key: home, __TSR_key: home }, '', base + '#/');
      history.pushState({ __TSR_index: 1, key: here, __TSR_key: here }, '', base + hash);
    }
  } catch {}

  /*
   * tvOS can drop a web view's stored data between launches, and with it the
   * page's sign-in. The app keeps a copy of localStorage (by origin), puts
   * back what is missing as the page starts, and hears of every change.
   */
  try {
    const saved = __STORAGE__?.[location.origin];
    if (saved && typeof saved === 'object') {
      for (const [key, value] of Object.entries(saved)) {
        if (typeof value === 'string' && localStorage.getItem(key) === null)
          localStorage.setItem(key, value);
      }
    }
  } catch {}
  try {
    const proto = Storage.prototype;
    const { setItem, removeItem, clear } = proto;
    const local = (store) => {
      try {
        return store === window.localStorage;
      } catch {
        return false;
      }
    };
    const origin = location.origin;
    proto.setItem = function (key, value) {
      setItem.call(this, key, value);
      if (local(this))
        send({ type: 'tvos-storage', origin, key: String(key), value: String(value) });
    };
    proto.removeItem = function (key) {
      removeItem.call(this, key);
      if (local(this)) send({ type: 'tvos-storage', origin, key: String(key), value: null });
    };
    proto.clear = function () {
      clear.call(this);
      if (local(this)) send({ type: 'tvos-storage', origin, clear: true });
    };
  } catch {}

  // The app calls this with each message for the page.
  Object.defineProperty(window, '__aioReceive', {
    value(message) {
      if (message?.type === 'player-state') {
        const changed = stateChange(message);
        if (changed) diag('from-app', `player-state ${changed}`);
      } else if (!NOISY.has(message?.type)) {
        diag('from-app', brief(message));
      }
      if (skipped && message?.type === 'player-state') skipLanded(message);
      // A trailer that ends by itself is no longer playing, though the page sends no stop.
      if (message?.type === 'player-ended') {
        playing = false;
        inPlayer = false;
      }
      for (const listener of listeners) {
        try {
          listener(message);
        } catch (error) {
          diag('error', `a listener of ${message?.type}: ${error?.stack || error}`);
          console.error(error);
        }
      }
    },
  });

  window.aiostreamsApp = Object.freeze({
    protocol: 2,
    version: __VERSION__,
    // The page treats the Android app on a TV as a TV; tvOS gets the same.
    platform: 'android',
    tv: true,
    voice: false,
    pip: false,
    // The video can play in a box of the page, which trailers that start by themselves need.
    miniPlayer: true,
    /*
     * The app reads the remote itself (the keys below), so the page mustn't
     * poll gamepads: tvOS's WebKit lists the Siri Remote as one, and each OK
     * then reached the page twice, as Enter and as GamepadA, so a switch
     * flipped back and a pick list closed as it opened. Its touch surface
     * also counted as a stick, and the poll ran on every frame.
     */
    gamepadButtons: true,
    device: __DEVICE__,
    deviceId: __DEVICE_ID__,
    send,
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  });

  /*
   * The Siri Remote, as the keys the page's own remote handling reads. Back
   * goes through the bridge instead, as on Android.
   */
  const NOT_TEXT = new Set([
    'button', 'checkbox', 'radio', 'range', 'submit', 'reset',
    'color', 'file', 'image', 'hidden',
  ]);
  const isTextField = (el) =>
    !!el &&
    (el.tagName === 'TEXTAREA' ||
      (el.tagName === 'INPUT' && !NOT_TEXT.has((el.type || 'text').toLowerCase())));
  const target = () => document.activeElement || document.body;
  /*
   * On a TV the page marks the cards a row has scrolled out of sight
   * `data-nav-out`, and arrows skip them. A row measured while it was still
   * hidden, as Continue watching and Upcoming can be while they load, gets
   * every card marked, and stays so until the row itself scrolls: Down from
   * the hero then jumps past it. Before an up or down move, a row on screen
   * with every card marked gets the cards in its view back.
   */
  const unhideRows = () => {
    const rows = new Set();
    for (const card of document.querySelectorAll('[data-nav-row] > [data-nav-out]'))
      rows.add(card.parentElement);
    for (const row of rows) {
      if (row.querySelector(':scope > :not([data-nav-out])')) continue;
      const scroller = row.closest('[data-nav-self-scroll]') || row;
      const view = scroller.getBoundingClientRect();
      if (!view.width || !view.height || view.bottom < 0 || view.top > innerHeight * 2) continue;
      for (const card of row.children) {
        const box = card.getBoundingClientRect();
        if (box.width && box.right >= view.left && box.left <= view.right)
          card.removeAttribute('data-nav-out');
      }
    }
  };
  /*
   * A pick list's filter field (the settings' multi-selects): OK picks the
   * highlighted entry rather than opening the keyboard over it.
   */
  const picksFromList = (el) =>
    el.hasAttribute('cmdk-input') ||
    (el.getAttribute('role') === 'combobox' && !!el.getAttribute('aria-activedescendant'));
  let editing = null;
  let swallowed = false;
  /** Where OK went down, and when; see up(). The page's holds take 500 ms. */
  let heldOn = null;
  const HOLD_MS = 450;

  /** A control the remote is on, as the page's own keyboardFocus() reads it. */
  const keyboardFocus = () => {
    const el = document.activeElement;
    return (
      el instanceof HTMLElement &&
      el !== document.body &&
      el.matches(':focus-visible') &&
      !document.documentElement.hasAttribute('data-pointer-focus')
    );
  };
  /*
   * In the player with no control focused, the remote works as Apple's own
   * player does: OK plays or pauses (Space, so holding it still speeds up)
   * and Left/Right skip back and forward, rather than OK bringing focus to
   * the controls first. Up/Down still bring the controls; the skip button,
   * the next-episode card and any focused control keep their keys.
   */
  /** Once the controls are drawn, the subtitles button (else audio) takes focus. */
  const focusSubtitles = (tries = 10) => {
    const button = ['subtitles', 'audio']
      .map((n) => document.querySelector(`[data-ui=player-controls] button[data-name=${n}]`))
      .find((el) => el && el.getClientRects().length);
    if (button) {
      button.focus({ preventScroll: true, focusVisible: true });
      return;
    }
    if (tries > 0) setTimeout(() => focusSubtitles(tries - 1), 40);
  };
  const PLAYER_KEYS = { Enter: ' ', ArrowLeft: 'MediaRewind', ArrowRight: 'MediaFastForward' };
  const sent = new Map();
  /** Whether the element can be seen, rather than faded out with the controls. */
  const shown = (el) => {
    let opacity = 1;
    for (let node = el; node instanceof Element; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (style.visibility === 'hidden' || style.display === 'none') return false;
      opacity *= Number(style.opacity);
      if (opacity < 0.1) return false;
    }
    return true;
  };
  /*
   * A control the remote is on that can actually be seen. When the controls
   * fade, the page keeps focus on the control it was on; OK then pressed that
   * hidden button (play only toggled, without the scrub's position).
   */
  const visibleFocus = () => keyboardFocus() && shown(document.activeElement);
  /** Scrubbing paused through pictures, which OK plays from and the arrows step. */
  const scrubbing = () => !!document.querySelector('[data-ui=scrub-strip]');
  /*
   * The skip button stays until the seek past the segment lands, which over a
   * slow stream takes a few seconds; OK pressed again then skipped a second
   * time (and landed back where it was) instead of pausing. So OK plays and
   * pauses from the press until the player is at the segment's end, and
   * skips again if the seek never went out or the player gave up on it.
   */
  const SKIP_SEND_MS = 1500;
  const SKIP_MAX_MS = 20000;
  /** Seeks to keyframes, so it lands up to a second before the end. */
  const SKIP_SLACK_MS = 2500;
  const skipLanded = (state) => {
    const s = skipped;
    if (s.toMs == null) return;
    if (typeof state.seeking === 'boolean') {
      if (state.seeking) s.started = true;
      else if (s.started && !s.near) skipped = null; // gave up: OK skips again
    }
    const at = Number(state.positionMs);
    if (Number.isFinite(at) && at >= s.toMs - SKIP_SLACK_MS) {
      s.near = true;
      skipped = null;
    }
  };
  const skipButton = () => document.querySelector('[data-ui=skip-segment]');
  const skipPressed = (el) => {
    skipped = { el, at: Date.now(), toMs: null, started: false, near: false };
  };
  const skipUsed = (el) => {
    const s = skipped;
    if (!s || !el || s.el !== el) return false;
    const age = Date.now() - s.at;
    if ((s.toMs == null && age > SKIP_SEND_MS) || age > SKIP_MAX_MS) {
      skipped = null;
      return false;
    }
    return true;
  };
  const playerKey = (name) => {
    if (!inPlayer || !(name in PLAYER_KEYS)) return name;
    const skip = skipButton();
    if (name === 'Enter' && skipUsed(skip)) {
      // Off the used button, so OK goes to play and pause.
      if (skip.contains(document.activeElement)) document.activeElement.blur();
      return PLAYER_KEYS[name];
    }
    const onSkip = !!skip && skip.contains(document.activeElement);
    if (visibleFocus() && !scrubbing()) {
      if (name === 'Enter' && onSkip) skipPressed(skip);
      return name;
    }
    if (name === 'Enter' && skip?.matches('[data-visible]')) {
      skipPressed(skip);
      return name;
    }
    return PLAYER_KEYS[name];
  };

  const key = (type, name, repeat, at = target()) => {
    const el = at;
    const event = new KeyboardEvent(type, {
      key: name,
      code: name === ' ' ? 'Space' : name,
      repeat: !!repeat,
      bubbles: true,
      cancelable: true,
    });
    ours.add(event);
    const passed = el.dispatchEvent(event);
    diag('key', `${type} ${name === ' ' ? 'Space' : name}${repeat ? ' (repeat)' : ''} on ${describe(el)} → ${passed ? 'not taken' : 'taken'}`);
    return passed;
  };

  const setValue = (el, value) => {
    if (el.value === value) return;
    const proto =
      el.tagName === 'TEXTAREA'
        ? HTMLTextAreaElement.prototype
        : HTMLInputElement.prototype;
    // React tracks the value it last set, so set it as the browser would.
    Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
  };

  /** The app's keyboard, for a field: tvOS has none for a web page. */
  const openKeyboard = (el) => {
    editing = el;
    lastPress = null;
    send({
      type: 'tvos-keyboard',
      value: el.value || '',
      label:
        el.getAttribute('aria-label') ||
        el.placeholder ||
        el.labels?.[0]?.textContent?.trim() ||
        '',
      secure: el.type === 'password',
      email: el.type === 'email',
      numeric:
        el.inputMode === 'numeric' ||
        el.inputMode === 'decimal' ||
        el.type === 'number' ||
        el.type === 'tel',
      url: el.type === 'url',
    });
  };

  /*
   * The search box takes focus as the Search page opens; after the press that
   * opened it, the keyboard opens with it, rather than on a second press.
   * Arriving with the arrows leaves it closed.
   */
  let lastPress = null;
  document.addEventListener(
    'focusin',
    (e) => {
      const el = e.target;
      if (!isTextField(el) || el.type !== 'search' || picksFromList(el) || editing) return;
      if (lastPress?.name !== 'Enter' || Date.now() - lastPress.at > 3000) return;
      setTimeout(() => {
        if (document.activeElement === el && !editing) openKeyboard(el);
      }, 0);
    },
    true
  );

  /*
   * Smoothness and memory, each behind a switch here. The page itself stays
   * as the server sends it.
   */
  const STEADY_ROWS = true;
  const SOLID_PANELS = true;
  const RELEASE_PICTURES = true;

  /*
   * A row's placeholder cards are pictures only, and the cards that replace
   * them have their captions beneath, so every row that loads during a scroll
   * pushes what is under it down. The placeholders get the caption's height,
   * which the page gives each row as --poster-text (3.25rem under wide cards).
   */
  if (STEADY_ROWS) {
    const style = document.createElement('style');
    style.textContent =
      '[data-tv] [data-ui=media-row-item]>.UI-Skeleton__root{margin-bottom:var(--poster-text,0px)}' +
      '[data-tv] [data-ui=media-row-item]>.UI-Skeleton__root.aspect-video{margin-bottom:3.25rem}';
    const add = () => (document.head || document.documentElement)?.appendChild(style);
    if (document.documentElement) add();
    else document.addEventListener('readystatechange', add, { once: true });
  }

  /*
   * The page's bars and panels are frosted glass unless set otherwise
   * (Settings, Appearance, glass surface), which WebKit draws by blurring
   * what is behind them on every frame of a scroll. Solid once, on an app
   * that has never chosen; the page's own setting brings the glass back.
   */
  if (SOLID_PANELS) {
    try {
      const KEY = 'aiostreams-web-theme-glass-surface';
      if (!localStorage.getItem('tvos-glass-defaulted')) {
        localStorage.setItem('tvos-glass-defaulted', '1');
        if (localStorage.getItem(KEY) === null) localStorage.setItem(KEY, JSON.stringify('solid'));
      }
    } catch {}
  }

  /*
   * WebKit keeps every mounted picture decoded, so a long scroll fills its
   * process until tvOS ends it and the page loads again. A picture more than
   * three screens from the screen, or anywhere on the pages while the player
   * covers them, is swapped for a blank one, which lets WebKit drop it, and
   * put back within two screens. Home kept out of sight under another page
   * is left as it is, so going back to it shows it at once (and measuring a
   * page the browser has stopped drawing would make it lay that page out).
   * Rects are read together and pictures changed after, at most twice a
   * second while something moves and once after it stops, so a sweep lays
   * nothing out.
   */
  const BLANK = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
  const released = new WeakMap();
  const sweep = (keep = 2, drop = 3) => {
    const w = innerWidth;
    const h = innerHeight;
    if (!w || !h) return;
    const all = inPlayer;
    const marks = [];
    for (const img of document.images) {
      const held = released.get(img);
      const src = img.getAttribute('src') || '';
      if (held && src !== BLANK) {
        // The page gave it another picture meanwhile.
        released.delete(img);
        continue;
      }
      if (!held && (!src || src.startsWith('data:'))) continue;
      const covered = all && img.closest('[data-ui=shell]');
      if (!covered && img.closest('[data-page][inert]')) continue;
      const box = covered ? null : img.getBoundingClientRect();
      // Not drawn at all (a closed panel's): nothing to measure, so left alone.
      if (box && !box.width && !box.height) continue;
      const away = covered
        ? Infinity
        : Math.max(
            (box.top > h ? box.top - h : box.bottom < 0 ? -box.bottom : 0) / h,
            (box.left > w ? box.left - w : box.right < 0 ? -box.right : 0) / w
          );
      if (held ? away <= keep : away > drop) marks.push([img, held]);
    }
    for (const [img, held] of marks) {
      if (held) {
        released.delete(img);
        if (held.srcset !== null) img.setAttribute('srcset', held.srcset);
        img.setAttribute('src', held.src);
      } else {
        released.set(img, { src: img.getAttribute('src'), srcset: img.getAttribute('srcset') });
        img.removeAttribute('srcset');
        img.setAttribute('src', BLANK);
      }
    }
    if (marks.length) {
      const back = marks.filter(([, held]) => held).length;
      diag('pictures', `${marks.length - back} let go, ${back} put back, of ${document.images.length}`);
    }
  };
  let sweepTimer = 0;
  let sweptAt = 0;
  const soonSweep = () => {
    if (!RELEASE_PICTURES) return;
    clearTimeout(sweepTimer);
    const now = Date.now();
    if (now - sweptAt >= 500) {
      sweptAt = now;
      sweep();
    }
    // Where a scroll comes to rest.
    sweepTimer = setTimeout(() => {
      sweptAt = Date.now();
      sweep();
    }, 400);
  };
  if (RELEASE_PICTURES) {
    // Capture: the page and each row scroll in containers of their own.
    document.addEventListener('scroll', soonSweep, { capture: true, passive: true });
    addEventListener('hashchange', soonSweep);
  }

  Object.defineProperty(window, '__aioTV', {
    value: Object.freeze({
      down(name, repeat) {
        const el = target();
        if (name === 'Enter' && !repeat) heldOn = { el, at: Date.now() };
        // tvOS has no keyboard for a web page, so the app shows its own.
        lastPress = { name, at: Date.now() };
        if (name === 'Enter' && isTextField(el) && !picksFromList(el)) {
          if (repeat) return;
          swallowed = true;
          diag('key', `Enter on ${describe(el)} opens the app's keyboard`);
          openKeyboard(el);
          return;
        }
        if (!inPlayer && (name === 'ArrowDown' || name === 'ArrowUp')) unhideRows();
        // A held key repeats as whatever it went down as.
        const as = repeat && sent.has(name) ? sent.get(name) : playerKey(name);
        sent.set(name, as);
        const toSubtitles = name === 'ArrowDown' && !repeat && inPlayer && !visibleFocus() && !scrubbing();
        key('keydown', as, repeat);
        // A page that glides by transforms alone fires no scroll event.
        if (name.startsWith('Arrow')) soonSweep();
        // Down brings the controls with the subtitles button picked out, not opened.
        if (toSubtitles) focusSubtitles();
      },
      up(name) {
        if (name === 'Enter' && swallowed) {
          swallowed = false;
          return;
        }
        const as = sent.get(name) ?? name;
        sent.delete(name);
        /*
         * OK held until a menu opened, with focus now in it: letting go must
         * only end the hold, which the page ends where its keydown went (its
         * window keyup listener takes the release there and nothing else sees
         * it). The release goes to that element, so the menu doesn't get it,
         * and focus stays in the menu. A blur here used to end the hold, but
         * it also closed the menu.
         */
        const held = name === 'Enter' ? heldOn : null;
        if (name === 'Enter') heldOn = null;
        const now = document.activeElement;
        if (
          held && Date.now() - held.at >= HOLD_MS && now !== held.el &&
          now?.closest?.('[role=menu], [role=dialog], [role=alertdialog], [role=listbox]')
        ) {
          diag('key', `Enter let go after a hold that opened ${describe(now)}: ends the hold on ${describe(held.el)}`);
          if (held.el.isConnected) key('keyup', as, false, held.el);
          return;
        }
        key('keyup', as);
      },
      /** tvOS is short of memory: all but the screen and half of one around it lets go of its pictures. */
      trim() {
        diag('memory', 'tvOS warned of low memory');
        if (RELEASE_PICTURES) sweep(0.25, 0.5);
      },
      /** The page's diagnostics lines after line `since`, for the app. */
      log(since = 0) {
        return diagLines.filter((line) => Number(line.slice(1, line.indexOf(' '))) > since).join('\n');
      },
      clearLog() {
        diagLines.length = 0;
      },
      /** Each change on the app's search keyboard, as it is typed. */
      live(value) {
        if (editing?.isConnected) setValue(editing, value);
      },
      /** The text typed on the app's keyboard, for the field it was opened for. */
      type(value, submit) {
        const el = editing;
        editing = null;
        if (!el || !el.isConnected) return;
        setValue(el, value);
        el.dispatchEvent(new Event('change', { bubbles: true }));
        // Back on its field, which mustn't take that for a press opening the keyboard again.
        lastPress = null;
        el.focus();
        // After React has taken the new value.
        const form = el.form;
        if (submit && form)
          setTimeout(() => {
            if (form.requestSubmit) form.requestSubmit();
            else form.submit();
          }, 250);
      },
    }),
  });

  /** The page's route, which the app reopens on its next launch. */
  let lastRoute = null;
  const route = () => {
    if (location.hash === lastRoute) return;
    lastRoute = location.hash;
    diag('route', location.hash);
    send({ type: 'tvos-route', hash: location.hash });
  };
  for (const name of ['pushState', 'replaceState']) {
    const original = history[name];
    history[name] = function (...args) {
      const result = original.apply(this, args);
      route();
      return result;
    };
  }
  addEventListener('hashchange', route);
  addEventListener('popstate', route);

  window.addEventListener('error', (e) => {
    diag('error', `${e.message || e.error} (${e.filename || '?'}:${e.lineno || 0})`);
    send({ type: 'web-error', message: String(e.message || e.error) });
  });

  send({ type: 'hello' });
})();
