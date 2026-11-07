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

  const listeners = new Set();
  /** Whether the page's player is open, from what the page tells the app. */
  let inPlayer = false;
  /** A skip-segment press waiting for its seek to land; see playerKey. */
  let skipped = null;
  const send = (message) => {
    if (message?.type === 'player-load') inPlayer = true;
    else if (message?.type === 'player-stop') inPlayer = false;
    if (message?.type === 'player-seek' && skipped && skipped.toMs == null)
      skipped.toMs = Number(message.positionMs);
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
      if (skipped && message?.type === 'player-state') skipLanded(message);
      for (const listener of listeners) {
        try {
          listener(message);
        } catch (error) {
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
    gamepads: false,
    pip: false,
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

  const key = (type, name, repeat) =>
    target().dispatchEvent(
      new KeyboardEvent(type, {
        key: name,
        code: name === ' ' ? 'Space' : name,
        repeat: !!repeat,
        bubbles: true,
        cancelable: true,
      })
    );

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

  Object.defineProperty(window, '__aioTV', {
    value: Object.freeze({
      down(name, repeat) {
        const el = target();
        // tvOS has no keyboard for a web page, so the app shows its own.
        lastPress = { name, at: Date.now() };
        if (name === 'Enter' && isTextField(el) && !picksFromList(el)) {
          if (repeat) return;
          swallowed = true;
          openKeyboard(el);
          return;
        }
        if (!inPlayer && (name === 'ArrowDown' || name === 'ArrowUp')) unhideRows();
        // A held key repeats as whatever it went down as.
        const as = repeat && sent.has(name) ? sent.get(name) : playerKey(name);
        sent.set(name, as);
        const toSubtitles = name === 'ArrowDown' && !repeat && inPlayer && !visibleFocus() && !scrubbing();
        key('keydown', as, repeat);
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
        key('keyup', as);
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

  window.addEventListener('error', (e) =>
    send({ type: 'web-error', message: String(e.message || e.error) })
  );

  send({ type: 'hello' });
})();
