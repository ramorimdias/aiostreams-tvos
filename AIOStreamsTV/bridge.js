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
   * The page's saved copies of artwork come back as blob URLs too (its
   * Settings → Storage → Artwork), which showed as "?" logos and avatars.
   * Off, every picture loads straight from its address.
   */
  try {
    localStorage.setItem('aiostreams-web-cache-artwork', 'false');
  } catch {}

  const listeners = new Set();
  const send = (message) => handler.postMessage(JSON.stringify(message));

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
  let editing = null;
  let swallowed = false;

  const key = (type, name, repeat) =>
    target().dispatchEvent(
      new KeyboardEvent(type, {
        key: name,
        code: name,
        repeat: !!repeat,
        bubbles: true,
        cancelable: true,
      })
    );

  Object.defineProperty(window, '__aioTV', {
    value: Object.freeze({
      down(name, repeat) {
        const el = target();
        // tvOS has no keyboard for a web page, so the app shows its own.
        if (name === 'Enter' && isTextField(el)) {
          if (repeat) return;
          editing = el;
          swallowed = true;
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
          return;
        }
        key('keydown', name, repeat);
      },
      up(name) {
        if (name === 'Enter' && swallowed) {
          swallowed = false;
          return;
        }
        key('keyup', name);
      },
      /** The text typed on the app's keyboard, for the field it was opened for. */
      type(value, submit) {
        const el = editing;
        editing = null;
        if (!el || !el.isConnected) return;
        const proto =
          el.tagName === 'TEXTAREA'
            ? HTMLTextAreaElement.prototype
            : HTMLInputElement.prototype;
        // React tracks the value it last set, so set it as the browser would.
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
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

  window.addEventListener('error', (e) =>
    send({ type: 'web-error', message: String(e.message || e.error) })
  );

  send({ type: 'hello' });
})();
