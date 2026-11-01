/*
 * window.aiostreamsApp, the bridge AIOStreams' own apps give its web app
 * (protocol 2, as packages/android/bridge/AppBridge.kt injects it). The page
 * then lays itself out for a TV and plays through the app's player.
 *
 * The app fills in __VERSION__, __DEVICE__ and __DEVICE_ID__ as JSON strings.
 */
(() => {
  if (window.top !== window || window.aiostreamsApp) return;
  const handler = window.webkit?.messageHandlers?.aiostreamsNative;
  if (!handler) return;

  const listeners = new Set();
  const send = (message) => handler.postMessage(JSON.stringify(message));

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
        if (submit && el.form) {
          if (el.form.requestSubmit) el.form.requestSubmit();
          else el.form.submit();
        }
      },
    }),
  });

  window.addEventListener('error', (e) =>
    send({ type: 'web-error', message: String(e.message || e.error) })
  );

  send({ type: 'hello' });
})();
