// Scripts shoji puts into every page.
//
// pageWorldScript runs in the page's own JavaScript world (it has to, to see the
// page's console, errors and requests): it reports text-field focus, page changes,
// console output, errors and network activity to shoji.
//
// helperScript runs in shoji's own isolated world (the page can't see or break
// it): the page outline with short ids (snapshot) and the actions on it.

let pageWorldScript = """
(function () {
  if (window.__shojiPage) return;
  window.__shojiPage = true;
  const post = (name, msg) => { try { window.webkit.messageHandlers[name].postMessage(msg); } catch (e) {} };

  // --- text-field focus (Neovim sends keys to the page only while one has focus)
  function editable(e) {
    if (!e) return false;
    if (e.isContentEditable) return true;
    if (e.tagName === 'TEXTAREA' || e.tagName === 'SELECT') return true;
    if (e.tagName !== 'INPUT') return false;
    return !/^(button|submit|reset|checkbox|radio|image|file|range|color|hidden)$/i.test(e.type || '');
  }
  let last = null;
  function report() {
    const now = editable(document.activeElement);
    if (now === last) return;
    last = now;
    post('shojiFocus', now);
  }
  document.addEventListener('focusin', report, true);
  document.addEventListener('focusout', () => setTimeout(report, 0), true);
  window.addEventListener('pageshow', report);

  // --- page changes (DOM edits, animations, transitions): wake shoji up, at most every 100 ms
  let pending = false;
  function changed() {
    if (pending) return;
    pending = true;
    setTimeout(() => { pending = false; post('shojiWake', 1); }, 100);
  }
  new MutationObserver(changed).observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
  ['animationstart', 'animationiteration', 'transitionstart', 'transitionrun', 'load', 'resize'].forEach(t => window.addEventListener(t, changed, true));

  // --- console, errors, network (for agents: shoji ctl console / errors / network)
  // inside an iframe, say which one (macOS also knows from the message's frame info; WPE doesn't)
  const inFrame = (() => { try { return window !== window.top; } catch (e) { return true; } })();
  const log = o => post('shojiLog', inFrame ? Object.assign({ frame: location.href }, o) : o);
  const fmt = v => {
    if (typeof v === 'string') return v;
    if (v instanceof Error) return v.name + ': ' + v.message + (v.stack ? ' @ ' + String(v.stack).split('\\n')[0] : '');
    try { const s = JSON.stringify(v); return s === undefined ? String(v) : s; } catch (e) { return String(v); }
  };
  ['log', 'info', 'warn', 'error', 'debug'].forEach(level => {
    const orig = console[level];
    console[level] = function (...a) {
      log({ k: 'console', level: level === 'log' ? 'info' : level, text: a.map(fmt).join(' ').slice(0, 4000) });
      return orig.apply(this, a);
    };
  });
  window.addEventListener('error', e => {
    const t = e.target;
    if (t && t !== window && (t.src || t.href)) {
      log({ k: 'network', failed: true, url: String(t.src || t.href), type: t.tagName.toLowerCase(), error: 'failed to load' });
    } else {
      const where = e.filename ? ' (' + e.filename.split('/').pop() + ':' + e.lineno + ':' + e.colno + ')' : '';
      log({ k: 'error', text: (e.message || 'error') + where, stack: e.error && e.error.stack ? String(e.error.stack).slice(0, 4000) : undefined });
    }
  }, true);
  window.addEventListener('unhandledrejection', e => log({ k: 'error', text: 'Unhandled promise rejection: ' + fmt(e.reason) }));

  const origFetch = window.fetch;
  if (origFetch) window.fetch = function (input, init) {
    const url = String(input && input.url || input);
    const method = (init && init.method || input && input.method || 'GET').toUpperCase();
    const t0 = performance.now();
    return origFetch.apply(this, arguments).then(r => {
      log({ k: 'network', type: 'fetch', method, url: r.url || url, status: r.status, ms: Math.round(performance.now() - t0) });
      return r;
    }, err => {
      log({ k: 'network', type: 'fetch', method, url, failed: true, error: String(err && err.message || err), ms: Math.round(performance.now() - t0) });
      throw err;
    });
  };
  const XO = XMLHttpRequest.prototype.open, XS = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (m, u) { this.__shoji = { method: String(m).toUpperCase(), url: String(u) }; return XO.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function () {
    const info = this.__shoji, t0 = performance.now();
    if (info) this.addEventListener('loadend', () => log({ k: 'network', type: 'xhr', method: info.method, url: this.responseURL || info.url,
      status: this.status || undefined, failed: this.status === 0 || undefined, error: this.status === 0 ? 'failed' : undefined,
      ms: Math.round(performance.now() - t0) }));
    return XS.apply(this, arguments);
  };
  try {
    new PerformanceObserver(list => list.getEntries().forEach(en => {
      if (en.initiatorType === 'fetch' || en.initiatorType === 'xmlhttprequest') return;
      log({ k: 'network', type: en.initiatorType || 'resource', url: en.name, status: en.responseStatus || undefined,
            ms: Math.round(en.duration), size: en.transferSize || undefined });
    })).observe({ type: 'resource', buffered: true });
  } catch (e) {}
})();
"""

let helperScript = """
(function () {
  if (window.__shoji) return;
  const S = window.__shoji = { refs: new Map() };
  const txt = s => (s || '').replace(/\\s+/g, ' ').trim();
  const cut = (s, n) => s.length > n ? s.slice(0, n - 1) + '…' : s;

  S.role = e => {
    const r = e.getAttribute && e.getAttribute('role');
    if (r && !/^(none|presentation|generic)$/.test(r)) return r;
    const t = e.tagName;
    if (t === 'A' && e.hasAttribute('href')) return 'link';
    if (t === 'BUTTON' || t === 'SUMMARY') return 'button';
    if (t === 'INPUT') {
      const ty = (e.type || 'text').toLowerCase();
      if (/^(button|submit|reset|image)$/.test(ty)) return 'button';
      if (ty === 'checkbox') return 'checkbox';
      if (ty === 'radio') return 'radio';
      if (ty === 'range') return 'slider';
      if (ty === 'file') return 'button';
      if (ty === 'hidden') return null;
      return 'textbox';
    }
    if (t === 'TEXTAREA') return 'textbox';
    if (t === 'SELECT') return 'combobox';
    if (/^H[1-6]$/.test(t)) return 'heading';
    if (t === 'IMG') return e.alt ? 'img' : null;
    if (e.isContentEditable && !(e.parentElement && e.parentElement.isContentEditable)) return 'textbox';
    return null;
  };

  S.name = e => {
    const al = e.getAttribute('aria-label');
    if (al) return txt(al);
    const lb = e.getAttribute('aria-labelledby');
    if (lb) {
      const t = txt(lb.split(/\\s+/).map(id => document.getElementById(id)).filter(Boolean).map(x => x.innerText).join(' '));
      if (t) return t;
    }
    if (e.labels && e.labels.length) {
      const t = txt([...e.labels].map(l => {
        let s = l.textContent;
        if (l.contains(e) && e.textContent) s = s.replace(e.textContent, ' ');
        return s;
      }).join(' '));
      if (t) return t;
    }
    if (e.tagName === 'IMG') return txt(e.alt);
    if (e.tagName === 'INPUT' && /^(button|submit|reset)$/i.test(e.type)) return txt(e.value || e.type);
    if (!/^(INPUT|TEXTAREA|SELECT)$/.test(e.tagName)) {
      const own = txt(e.innerText);
      if (own) return cut(own, 80);
      // no text: a picture or icon inside (a logo link, an icon button)
      const inner = e.querySelector('img[alt]:not([alt=""]), [aria-label], svg title');
      if (inner) return cut(txt(inner.getAttribute('alt') || inner.getAttribute('aria-label') || inner.textContent), 80);
    }
    return txt(e.placeholder || e.title || e.name || '');
  };

  S.visible = e => {
    if (!e.isConnected) return false;
    const st = getComputedStyle(e);
    if (st.visibility === 'hidden' || st.display === 'none' || +st.opacity === 0) return false;
    const r = e.getClientRects();
    return r.length > 0 && (r[0].width > 0 || r[0].height > 0);
  };

  function shortHref(h) {
    try {
      const u = new URL(h, location.href);
      if (u.origin === location.origin) return cut(u.pathname + u.search + u.hash, 60);
      return cut(u.host + u.pathname, 60);
    } catch (e) { return cut(h, 60); }
  }

  S.state = e => {
    const p = [];
    const r = S.role(e);
    if (r === 'heading') p.push('level=' + e.tagName[1]);
    if (r === 'textbox') {
      const v = e.isContentEditable ? txt(e.innerText) : e.value;
      p.push('value="' + cut(v || '', 40) + '"');
      if (!e.value && e.placeholder && S.name(e) !== txt(e.placeholder)) p.push('placeholder="' + cut(txt(e.placeholder), 30) + '"');
    }
    if (r === 'checkbox' || r === 'radio') p.push(e.checked ? 'checked' : 'unchecked');
    if (r === 'combobox' && e.tagName === 'SELECT') {
      const o = e.options[e.selectedIndex];
      p.push('selected="' + cut(o ? txt(o.text) : '', 30) + '" options=' + e.options.length);
    }
    if (r === 'link') p.push('→ ' + shortHref(e.getAttribute('href')));
    if (e.disabled || e.getAttribute('aria-disabled') === 'true') p.push('disabled');
    const ex = e.getAttribute('aria-expanded');
    if (ex) p.push(ex === 'true' ? 'expanded' : 'collapsed');
    return p.length ? ' ' + p.join(' ') : '';
  };

  // Elements with their own text (paragraphs, list items, cells…), for snapshot --text
  const TEXT_TAGS = /^(P|LI|TD|TH|DD|DT|BLOCKQUOTE|FIGCAPTION|LABEL|PRE|CAPTION|SPAN|DIV)$/;
  function ownText(e) {
    if (!TEXT_TAGS.test(e.tagName)) return '';
    let s = '';
    for (const n of e.childNodes) if (n.nodeType === 3) s += n.textContent;
    return txt(s);
  }

  S.snapshot = (opts) => {
    opts = opts || {};
    S.refs = new Map();
    const lines = [], max = opts.max || 400, vh = innerHeight;
    let n = 0, total = 0;
    const walk = root => {
      const w = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
      let e;
      while ((e = w.nextNode())) {
        if (e.shadowRoot) walk(e.shadowRoot);
        const r = S.role(e);
        if (!r) {
          if (opts.text) {
            const t = ownText(e);
            if (t.length > 1 && S.visible(e)) { total++; if (lines.length < max) lines.push('text: ' + cut(t, 200)); }
          }
          continue;
        }
        if (!S.visible(e)) continue;
        const rect = e.getBoundingClientRect();
        if (opts.view && (rect.bottom < 0 || rect.top > vh)) continue;   // only what's on screen
        total++;
        if (lines.length >= max) continue;
        const ref = 'e' + (++n);
        S.refs.set(ref, e);
        const where = rect.bottom < 0 ? ' ↑' : rect.top > vh ? ' ↓' : '';
        lines.push(r + ' "' + S.name(e) + '" [' + ref + ']' + S.state(e) + where);
      }
    };
    walk(document.body || document.documentElement);
    return { title: document.title, url: location.href, lines, total, shown: lines.length,
             scrollY: Math.round(scrollY), pageHeight: document.documentElement.scrollHeight, viewport: [innerWidth, innerHeight] };
  };

  // A target: a ref from the last snapshot (e12), text=…, css=…, a CSS selector, or visible text.
  S.find = spec => {
    spec = String(spec);
    if (/^e\\d+$/.test(spec)) {
      const e = S.refs.get(spec);
      if (!e) throw new Error('unknown ref ' + spec + ' (take a new snapshot)');
      if (!e.isConnected) throw new Error('ref ' + spec + ' is gone: the page changed (take a new snapshot)');
      return e;
    }
    if (spec.startsWith('css=')) {
      const e = document.querySelector(spec.slice(4));
      if (!e) throw new Error('no element matches ' + spec.slice(4));
      return e;
    }
    let text = spec;
    if (spec.startsWith('text=')) text = spec.slice(5);
    else {
      try { const e = document.querySelector(spec); if (e) return e; } catch (err) {}
    }
    const want = txt(text).toLowerCase();
    let exact = null, partial = null, any = null;
    const w = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_ELEMENT);
    let e;
    while ((e = w.nextNode())) {
      if (!S.role(e) || !S.visible(e)) continue;
      const nm = S.name(e).toLowerCase();
      if (nm === want) { exact = e; break; }
      if (!partial && nm.includes(want)) partial = e;
    }
    if (!exact && !partial) {
      // any visible element whose text matches (e.g. a clickable div)
      const w2 = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_ELEMENT);
      while ((e = w2.nextNode())) {
        if (!S.visible(e)) continue;
        const t = txt(e.innerText).toLowerCase();
        if (t === want) any = e;     // keep the innermost match
      }
    }
    const found = exact || partial || any;
    if (!found) throw new Error('nothing named "' + text + '" (try shoji ctl snapshot)');
    return found;
  };

  const describe = e => (S.role(e) || e.tagName.toLowerCase()) + (S.name(e) ? ' "' + cut(S.name(e), 40) + '"' : '');

  // Scroll a target into view; where to click it, and whether something covers it.
  S.point = spec => {
    const e = S.find(spec);
    e.scrollIntoView({ block: 'center', inline: 'center' });
    const r = e.getBoundingClientRect();
    const x = r.left + r.width / 2, y = r.top + r.height / 2;
    const hit = document.elementFromPoint(x, y);
    const covered = hit && hit !== e && !e.contains(hit) && !hit.contains(e) ? describe(hit) : null;
    S.lastTarget = e;
    return { x, y, what: describe(e), covered };
  };
  S.clickLast = () => { if (S.lastTarget) S.lastTarget.click(); return true; };

  S.fill = (spec, value) => {
    const e = S.find(spec);
    e.scrollIntoView({ block: 'center' });
    e.focus();
    if (e.isContentEditable) {
      document.execCommand('selectAll', false);
      document.execCommand('insertText', false, value);
      return { what: describe(e), value: txt(e.innerText) };
    }
    if (!/^(INPUT|TEXTAREA)$/.test(e.tagName)) throw new Error(describe(e) + ' is not a text field');
    const proto = e.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, 'value').set.call(e, value);
    e.dispatchEvent(new Event('input', { bubbles: true }));
    e.dispatchEvent(new Event('change', { bubbles: true }));
    return { what: describe(e), value: e.value };
  };

  S.select = (spec, value) => {
    const e = S.find(spec);
    if (e.tagName !== 'SELECT') throw new Error(describe(e) + ' is not a select');
    const v = txt(value).toLowerCase();
    const opts = [...e.options];
    const o = opts.find(o => txt(o.text).toLowerCase() === v || o.value === value)
           || opts.find(o => txt(o.text).toLowerCase().includes(v));
    if (!o) throw new Error('no option "' + value + '"; options: ' + opts.map(o => txt(o.text)).join(', '));
    e.value = o.value;
    e.dispatchEvent(new Event('input', { bubbles: true }));
    e.dispatchEvent(new Event('change', { bubbles: true }));
    return { what: describe(e), selected: txt(o.text) };
  };

  // Is a checkbox/radio in the wanted state already? (then check/uncheck does nothing)
  S.checked = spec => !!S.find(spec).checked;
})();
"""
