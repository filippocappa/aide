"""The browser Aide's errands use (docs/API.md, "Browser errands"): Chromium through Playwright on this machine.

Each site gets its own persistent profile (data/browser/<site>/), so the user logs in once and its cookies stay.
Pages are sized like a phone, so the app's live view fits the screen. Each owner (an errand, "errand:3", or a login
the user opened from Settings, "site:amazon.it") has its own pages, one per site, and a current one.

The model reads a page as a list (`read`): its text, and a [ref] for each thing that can be clicked, typed in or
chosen. Password and card fields never show their value. The live view is the page's screencast; the user's taps and
typing go straight to the page (never to the model, never logged or stored).
"""

import asyncio
import base64
import logging
import re
import shutil
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Awaitable, Callable
from urllib.parse import urlparse

log = logging.getLogger(__name__)

VIEWPORT = {"width": 412, "height": 915}  # a large phone, in CSS pixels
SCALE = 2  # device pixels per CSS pixel: sharp enough in the app's live view
LOAD_TIMEOUT = 30_000  # ms for a page to load
ACTION_TIMEOUT = 8_000  # ms for a click or a fill
SETTLE = 0.8  # seconds after an action for the page to react
READ_LIMIT = 6000  # characters of a page listing
IDLE = 15 * 60  # seconds a site's browser stays open with no page in use
# Two-part public suffixes, so www.amazon.co.uk is amazon.co.uk (one profile per site).
_SECOND_LEVEL = {"co.uk", "org.uk", "ac.uk", "com.au", "co.jp", "com.br", "co.in", "com.mx", "co.nz", "com.tr"}
_SITE = re.compile(r"^[a-z0-9.-]+\.[a-z]{2,}$")

# Mobile Chrome on Android, with this Chromium's version (set at launch).
_UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/{v} Mobile Safari/537.36"


class BrowserError(Exception):
    """Something the model should read and act on (no such ref, a page that didn't load)."""


def site_of(url: str) -> str:
    """The registrable domain of a URL: https://www.amazon.it/s?k=x is amazon.it."""
    host = (urlparse(url if "//" in url else "https://" + url).hostname or "").lower().rstrip(".")
    parts = host.split(".")
    if len(parts) >= 3 and ".".join(parts[-2:]) in _SECOND_LEVEL:
        return ".".join(parts[-3:])
    site = ".".join(parts[-2:])
    if not _SITE.match(site):
        raise ValueError(f"not a web address: {url!r}")
    return site


def check_site(site: str) -> str:
    if not _SITE.match(site) or ".." in site:
        raise ValueError(f"not a site: {site!r}")
    return site


def full_url(url: str) -> str:
    url = url.strip()
    if not re.match(r"^https?://", url):
        url = "https://" + url
    site_of(url)  # raises for something that isn't a web address
    return url


# Lists the page for the model: text in reading order, and a [ref] line for each visible thing that can be clicked,
# typed in or chosen. Refs are kept on the elements (data-aide-ref), so they stay the same while the page does.
_READ_JS = r"""
(args) => {
  const everything = args.everything, LIMIT = args.limit, vh = window.innerHeight;
  const INTERACTIVE = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],' +
    '[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=option],[role=combobox],[role=switch],' +
    '[contenteditable=""],[contenteditable=true],[onclick]';
  const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'SVG', 'TEMPLATE', 'HEAD']);
  let next = Number(document.documentElement.dataset.aideNext || 1);
  const lines = [];
  let chars = 0, more = false, text = '';
  const seen = new WeakMap();
  const shown = (el) => {
    if (!el) return false;
    if (seen.has(el)) return seen.get(el);
    const r = el.getBoundingClientRect(), s = getComputedStyle(el);
    let ok = r.width >= 1 && r.height >= 1 && s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0';
    if (ok && !everything && (r.bottom < -vh * 0.25 || r.top > vh * 1.75)) { ok = false; if (r.top > vh) more = true; }
    seen.set(el, ok);
    return ok;
  };
  const clean = (t) => (t || '').replace(/\s+/g, ' ').trim();
  const push = (line) => {
    if (chars > LIMIT) { more = true; return; }
    lines.push(line); chars += line.length + 1;
  };
  const flush = () => { if (text) { push(text); text = ''; } };
  const sensitive = (el) => el.type === 'password' ||
    /cc-|card|cvv|cvc|csc|iban|expir/i.test([el.autocomplete, el.name, el.id].join(' '));
  const label = (el) => {
    const byLabel = el.labels && el.labels.length ? el.labels[0].innerText : '';
    const img = el.querySelector && el.querySelector('img[alt]');
    return clean(el.getAttribute('aria-label') || byLabel || (el.tagName === 'INPUT' ? '' : el.innerText) ||
      el.getAttribute('placeholder') || el.getAttribute('title') || (img && img.alt) || el.getAttribute('alt') ||
      (['submit', 'button'].includes(el.type) ? el.value : '') || el.name || '').slice(0, 120);
  };
  const emit = (el) => {
    flush();
    let ref = el.dataset.aideRef;
    if (!ref) { ref = String(next++); el.dataset.aideRef = ref; }
    const tag = el.tagName.toLowerCase();
    let kind = el.getAttribute('role') ||
      {a: 'link', button: 'button', select: 'select', textarea: 'textbox', summary: 'button'}[tag] || tag;
    if (tag === 'input') {
      kind = ['submit', 'button', 'image', 'reset'].includes(el.type) ? 'button'
        : ['checkbox', 'radio'].includes(el.type) ? el.type : 'input:' + (el.type || 'text');
    }
    let line = `[${ref}] ${kind} "${label(el)}"`;
    if (tag === 'input' || tag === 'textarea') {
      if (sensitive(el)) line += el.value ? ' (filled, hidden)' : ' (for the user)';
      else if (el.value && !['submit', 'button', 'checkbox', 'radio'].includes(el.type))
        line += ` value="${clean(el.value).slice(0, 80)}"`;
    }
    if (tag === 'select') {
      const opts = [...el.options].slice(0, 15).map(o => clean(o.text)).join(' | ');
      line += ` value="${clean(el.selectedOptions[0] ? el.selectedOptions[0].text : '')}" options: ${opts}`;
    }
    if (tag === 'a' && el.href && /^https?:/.test(el.href)) {  // where it goes, so links can be given to the user
      const u = new URL(el.href);
      let path = (u.host === location.host ? '' : u.host) + u.pathname;
      if (path.length > 80) path = '…' + path.slice(-60);
      if (path !== '/') line += ` → ${path}`;
    }
    if (el.checked || el.getAttribute('aria-checked') === 'true') line += ' checked';
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') line += ' disabled';
    if (document.activeElement === el) line += ' (focused)';
    push(line);
  };
  const walk = (node) => {
    if (chars > LIMIT) { more = true; return; }
    if (node.nodeType === 3) {
      const t = clean(node.textContent);
      if (t && shown(node.parentElement)) {
        text = text ? text + ' ' + t : t;
        if (text.length > 240) flush();
      }
      return;
    }
    if (node.nodeType !== 1 || SKIP.has(node.tagName.toUpperCase())) return;
    if (node.tagName === 'IFRAME') {
      if (shown(node)) { flush(); push(`[frame: ${(node.title || node.src || '').slice(0, 80)}]`); }
      return;
    }
    if (node.matches(INTERACTIVE)) { if (shown(node)) emit(node); return; }
    if (/^H[1-3]$/.test(node.tagName)) flush();
    if (node.shadowRoot) for (const c of node.shadowRoot.childNodes) walk(c);
    for (const c of node.childNodes) walk(c);
    if (/^(H[1-6]|P|LI|TR|DIV|SECTION|ARTICLE|HEADER|FOOTER|NAV|FORM|UL|OL|TABLE)$/.test(node.tagName)) flush();
  };
  walk(document.body || document.documentElement);
  flush();
  document.documentElement.dataset.aideNext = String(next);
  const screens = Math.max(1, Math.ceil(document.documentElement.scrollHeight / vh));
  const at = Math.min(screens, Math.round(window.scrollY / vh) + 1);
  return {title: document.title, url: location.href, lines, more, at, screens};
}
"""

_FIND_JS = r"""
(needle) => {
  needle = needle.toLowerCase();
  const INTERACTIVE = 'a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=option],[onclick]';
  let next = Number(document.documentElement.dataset.aideNext || 1);
  const out = [];
  const all = [...document.querySelectorAll('body *')].filter(el => {
    const t = (el.innerText || el.value || el.getAttribute('aria-label') || '').toLowerCase();
    return t.includes(needle) && ![...el.children].some(c => (c.innerText || '').toLowerCase().includes(needle));
  });
  for (const el of all.slice(0, 12)) {
    const target = el.closest(INTERACTIVE) || el;
    let ref = target.dataset.aideRef;
    if (!ref) { ref = String(next++); target.dataset.aideRef = ref; }
    const r = el.getBoundingClientRect();
    const where = r.top < 0 ? 'above' : r.top > innerHeight ? 'below' : 'on screen';
    out.push(`[${ref}] ${target.tagName.toLowerCase()} "${(target.innerText || target.value || '').replace(/\s+/g, ' ').trim().slice(0, 140)}" (${where})`);
  }
  document.documentElement.dataset.aideNext = String(next);
  return out;
}
"""

_INSPECT_JS = r"""
(el) => {
  const sensitive = el.type === 'password' ||
    /cc-|card|cvv|cvc|csc|iban|expir/i.test([el.autocomplete, el.name, el.id].join(' '));
  const text = [el.getAttribute('aria-label'), el.innerText, el.type === 'password' ? '' : el.value,
                el.getAttribute('title'), el.getAttribute('alt')].filter(Boolean).join(' ').replace(/\s+/g, ' ').trim();
  // The button Enter in this field would press: the form's submit button.
  const form = el.form || (el.closest && el.closest('form'));
  const submit = form && el.tagName !== 'BUTTON' &&
    form.querySelector('button[type=submit],input[type=submit],button:not([type])');
  const submits = submit ? (submit.innerText || submit.value || submit.getAttribute('aria-label') || '') : '';
  return {tag: el.tagName.toLowerCase(), type: el.type || '', text: text.slice(0, 200), sensitive,
          submits: submits.replace(/\s+/g, ' ').trim().slice(0, 120)};
}
"""

# Each link's picture, for the product cards: [{path, src, alt}] (path as the page listing writes it), plus pictures
# with a long alt text and no link (a checkout's items). The picture is the first one in the link's card: the link,
# or an ancestor up to 6 levels that holds no picture linked somewhere else (that would be the whole list).
_IMAGES_JS = r"""
() => {
  const src = img => {
    const s = img.currentSrc || img.src || '';
    if (!/^https?:/.test(s)) return null;
    const r = img.getBoundingClientRect();
    return (img.naturalWidth || r.width) >= 60 && (img.naturalHeight || r.height) >= 60 ? s : null;
  };
  const pathOf = a => {
    try { const u = new URL(a.href); return (u.host === location.host ? '' : u.host) + u.pathname; } catch (e) { return null; }
  };
  const same = (a, b) => a.replace(/\/ref=.*$/, '') === b.replace(/\/ref=.*$/, '');
  const out = [], seen = new Set();
  for (const a of document.querySelectorAll('a[href]')) {
    const path = pathOf(a);
    if (!path || path === '/' || seen.has(path)) continue;
    let el = a;
    for (let i = 0; i < 6 && el && el !== document.body; i++, el = el.parentElement) {
      const imgs = [...el.querySelectorAll('img')].filter(src);
      if (imgs.some(img => { const l = img.closest('a[href]'); const p = l && pathOf(l); return p && !same(p, path); })) break;
      if (imgs.length) {
        seen.add(path);
        out.push({path, src: src(imgs[0]), alt: (imgs[0].alt || '').slice(0, 200)});
        break;
      }
    }
  }
  for (const img of document.querySelectorAll('img[alt]')) {
    if (!img.closest('a[href]') && img.alt.trim().length >= 12 && src(img)) {
      out.push({path: null, src: src(img), alt: img.alt.trim().slice(0, 200)});
    }
  }
  return out.slice(0, 400);
}
"""

# A product page's picture: its og:image, else the largest picture near the top.
_MAIN_IMAGE_JS = r"""
() => {
  const meta = document.querySelector('meta[property="og:image"],meta[name="og:image"],meta[name="twitter:image"]');
  if (meta && /^https?:/.test(meta.content || '')) return meta.content;
  let best = null, area = 0;
  for (const img of document.images) {
    const r = img.getBoundingClientRect(), s = img.currentSrc || img.src || '';
    if (!/^https?:/.test(s) || r.width < 100 || r.top > innerHeight * 1.5) continue;
    if (r.width * r.height > area) { area = r.width * r.height; best = s; }
  }
  return best;
}
"""

# What the focused element wants, so the app can show the right native field (AutoFill for passwords and codes).
_FOCUS_JS = r"""
() => {
  const el = document.activeElement;
  if (!el || !(el.matches('input,textarea') || el.isContentEditable)) return {field: null};
  const hint = [el.autocomplete, el.name, el.id, el.getAttribute('inputmode')].join(' ').toLowerCase();
  let field = 'text';
  if (el.type === 'password') field = 'password';
  else if (/one-time-code|otp|2fa|mfa|verification|codice|code/.test(hint)) field = 'code';
  else if (el.type === 'email' || /email|username|user|login|account/.test(hint)) field = 'username';
  else if (el.type === 'tel') field = 'phone';
  else if (el.type === 'number' || /numeric/.test(hint)) field = 'number';
  const label = (el.getAttribute('aria-label') || (el.labels && el.labels[0] && el.labels[0].innerText) ||
                 el.placeholder || '').replace(/\s+/g, ' ').trim().slice(0, 60);
  return {field, label};
}
"""

# What kind of page this is and the few real things on it, for the app's animated view of an errand (it never draws
# the site itself) and its own login screen: {kind, site, title, url, icon, query, items, product, cart, form,
# captcha}. kind: captcha, login, code, checkout, confirmation, cart, product, results or page. Refs are the page
# listing's (data-aide-ref), so the model's and the app's are the same. Password values are never read.
_SCENE_JS = r"""
() => {
  let next = Number(document.documentElement.dataset.aideNext || 1);
  const refOf = el => { let r = el.dataset.aideRef; if (!r) { r = String(next++); el.dataset.aideRef = r; } return r; };
  const clean = t => (t || '').replace(/\s+/g, ' ').trim();
  const vh = innerHeight;
  const visible = el => {
    if (!el) return false;
    const r = el.getBoundingClientRect(), s = getComputedStyle(el);
    return r.width >= 2 && r.height >= 2 && s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0';
  };
  const abs = u => { try { return u ? new URL(u, location.href).href : null; } catch (e) { return null; } };
  const PRICE = /(?:(?:[€$£]|EUR|USD|GBP)\s?\d{1,3}(?:[.\s]?\d{3})*(?:\s?[.,]\s?\d{2})?|\d{1,3}(?:[.\s]?\d{3})*(?:\s?[.,]\s?\d{2})?\s?(?:€|EUR\b|USD\b|GBP\b))/;
  const priceIn = t => { const m = clean(t).match(PRICE); return m ? m[0].replace(/\s?([.,])\s?(\d{2})\b/, '$1$2').trim() : null; };
  const imgSrc = img => {
    const s = img && (img.currentSrc || img.src) || '';
    if (!/^https?:/.test(s)) return null;
    const r = img.getBoundingClientRect();
    return (img.naturalWidth || r.width) >= 60 && (img.naturalHeight || r.height) >= 60 ? s : null;
  };
  const labelOf = el => clean(el.getAttribute('aria-label') || (el.labels && el.labels[0] && el.labels[0].innerText) ||
    el.placeholder || el.getAttribute('title') || '').slice(0, 60);
  const textOf = el => clean(el.innerText || el.value || el.getAttribute('aria-label') || '').slice(0, 120);
  const body = clean(document.body ? document.body.innerText.slice(0, 30000) : '');
  const lower = body.toLowerCase();
  const path = decodeURIComponent(location.pathname).toLowerCase();
  const params = new URLSearchParams(location.search);
  const meta = n => { const m = document.querySelector(`meta[property="${n}"],meta[name="${n}"]`); return m ? clean(m.content) : null; };
  const buttons = () => [...document.querySelectorAll('button,input[type=submit],input[type=button],a[role=button],[role=button]')].filter(visible);

  // The fields on the page, by what they want.
  const kindOf = el => {
    const hint = [el.autocomplete, el.name, el.id, el.getAttribute('inputmode'), el.placeholder, labelOf(el)].join(' ').toLowerCase();
    if (['checkbox', 'radio', 'submit', 'button', 'image', 'reset', 'file', 'range', 'color', 'hidden'].includes(el.type)) return null;
    if (el.type === 'password') return 'password';
    if (el.type === 'search' || /search|cerca|field-keywords|query|\bq\b/.test(hint)) return 'search';
    if (el.type !== 'email' && /one-time-code|otp|2fa|mfa|verif|codice|\bcode\b|\bpin\b/.test(hint)) return 'code';
    if (el.type === 'email' || /email|e-mail|username|user|login|account|claim/.test(hint)) return 'username';
    if (el.type === 'tel' || /\btel\b|phone|cellulare|telefono|mobile/.test(hint)) return 'phone';
    return 'text';
  };
  const inputs = [...document.querySelectorAll('input,textarea')].filter(visible).map(el => ({el, kind: kindOf(el)})).filter(f => f.kind);
  const search = inputs.find(f => f.kind === 'search');
  const query = clean((search && search.el.value) || params.get('k') || params.get('q') || params.get('query') ||
    params.get('search') || params.get('keywords') || '').slice(0, 80) || null;
  const pathOf = a => { try { const u = new URL(a.href); return u.host + u.pathname.replace(/\/ref=.*$/, ''); } catch (e) { return null; } };
  const iconEl = document.querySelector('link[rel~="apple-touch-icon"],link[rel~="icon"],link[rel="shortcut icon"]');
  const out = {kind: 'page', site: location.hostname.replace(/^www\./, ''), title: clean(document.title).slice(0, 100),
               url: location.href, icon: abs(iconEl ? iconEl.getAttribute('href') : '/favicon.ico'), query,
               items: [], product: null, cart: null, form: null, captcha: null};

  // A CAPTCHA: a challenge frame, or a picture of characters to type.
  const challenge = /captcha|robot|human|umano|verifica|verify|security check|controllo di sicurezza|caratteri/i.test(body.slice(0, 4000));
  const frame = [...document.querySelectorAll('iframe')].find(f => visible(f) && !f.closest('.grecaptcha-badge') &&
    /recaptcha|hcaptcha|turnstile|challenges\.cloudflare|arkose|funcaptcha|captcha/i.test((f.src || '') + ' ' + (f.title || '')) &&
    f.getBoundingClientRect().width >= 120);
  const picture = [...document.images].find(img => visible(img) && /captcha/i.test([img.src, img.alt, img.id, img.className].join(' ')));
  if (picture || (frame && challenge)) {
    const holder = picture ? (picture.closest('form') || document.body) : document.body;
    const input = picture && [...holder.querySelectorAll('input')].find(i => visible(i) && ['text', 'search', ''].includes(i.type || ''));
    const submit = picture && [...holder.querySelectorAll('button,input[type=submit]')].find(visible);
    const kind = picture ? 'text' : /bframe|challenge/i.test(frame.src) ? 'grid'
      : /recaptcha|turnstile|hcaptcha/i.test(frame.src) ? 'checkbox' : 'other';
    out.kind = 'captcha';
    out.captcha = {kind, ref: refOf(picture || frame), input_ref: input ? refOf(input) : null,
                   submit_ref: submit ? refOf(submit) : null};
  }

  // A login or a code: the fields, the button that sends them, the choices and "stay logged in".
  const pw = inputs.find(f => f.kind === 'password'), code = inputs.find(f => f.kind === 'code');
  const user = inputs.find(f => f.kind === 'username' || f.kind === 'phone');
  const loginish = /sign.?in|log.?in|signin|accedi|accesso|anmelden|connexion|iniciar|\/ap\/|auth|account/.test(path + ' ' + out.title.toLowerCase());
  const codeish = code && (code.el.autocomplete === 'one-time-code' || (code.el.maxLength > 0 && code.el.maxLength <= 8) ||
    /codice|code|otp|verifica|verification|sms/.test(lower.slice(0, 3000)));
  if (out.kind === 'page' && (pw || codeish || (user && loginish && !search))) {
    const first = (pw || (codeish && code) || user).el;
    const root = first.form || first.closest('form,[role=dialog],main') || document.body;
    const fields = inputs.filter(f => root.contains(f.el) && ['username', 'password', 'code', 'phone', 'text'].includes(f.kind))
      .slice(0, 4).map(f => ({ref: refOf(f.el), kind: f.kind, label: labelOf(f.el) || null, filled: !!f.el.value}));
    const GO = /continu|accedi|sign.?in|log.?in|avanti|next|verific|verify|invia|submit|conferma|confirm|ok\b|entra/i;
    const submit = [...root.querySelectorAll('button[type=submit],input[type=submit]')].find(visible) ||
      [...root.querySelectorAll('button,[role=button],input[type=button],a')].filter(visible).find(b => GO.test(textOf(b)));
    const choices = [...root.querySelectorAll('input[type=radio]')].filter(r => visible(r) || (r.labels && r.labels[0] && visible(r.labels[0])))
      .slice(0, 6).map(r => ({ref: refOf(r), text: clean((r.labels && r.labels[0] && r.labels[0].innerText) || r.value).slice(0, 80)}));
    const remember = [...root.querySelectorAll('input[type=checkbox]')].find(c =>
      /resta|ricorda|remember|keep me|stay|mantieni/i.test(clean((c.labels && c.labels[0] && c.labels[0].innerText) || c.name || c.id)));
    const alert = [...document.querySelectorAll('[role=alert],[aria-live=assertive],[class*=error],[class*=alert],[id*=error]')]
      .find(a => visible(a) && clean(a.innerText).length > 3 && clean(a.innerText).length < 300);
    out.kind = pw || !codeish ? 'login' : 'code';
    const said = submit && (textOf(submit) || (submit.parentElement && textOf(submit.parentElement)));
    out.form = {fields, submit: submit ? {ref: refOf(submit), text: said || null} : null, choices,
                remember: remember ? refOf(remember) : null, remembered: remember ? remember.checked : null,
                error: alert ? clean(alert.innerText).slice(0, 200) : null};
  }

  // Result tiles: each product link's card (the biggest box around it with no other link's picture), with its
  // picture, name and price.
  const tiles = [], seen = new Set(), pictures = new Set(), names = new Set();
  const AD = /^(annuncio sponsorizzato|sponsorizzato|sponsored|ad|pubblicità)\s*[–:-]?\s*/i;
  const CTA = /^(scopri|discover|shop now|acquista ora|vedi tutt|see all|mostra|show more)/i;
  for (const a of document.querySelectorAll('a[href]')) {
    if (tiles.length >= 24) break;
    const p = pathOf(a);
    if (!p || seen.has(p) || !visible(a) || a.closest('header,nav,footer,[role=navigation],[role=banner],#nav-belt,#nav-main')) continue;
    seen.add(p);
    let card = null;
    for (let i = 0, el = a; i < 8 && el && el !== document.body; i++, el = el.parentElement) {
      const imgs = [...el.querySelectorAll('img')].filter(imgSrc);
      if (imgs.some(img => { const l = img.closest('a[href]'); return l && pathOf(l) !== p; })) break;
      if (imgs.length) card = el;
    }
    if (!card) continue;
    const img = [...card.querySelectorAll('img')].find(imgSrc);
    const named = [...card.querySelectorAll('h2,h3,h4'), ...card.querySelectorAll('[class*=title],[class*=Title],[class*=name],[class*=Name]'),
                   ...card.querySelectorAll('a')].map(textOf).map(t => t.replace(AD, '')).filter(t => t.length >= 6 && !PRICE.test(t) && !CTA.test(t));
    const title = (named[0] || clean(img.alt).replace(AD, '')).slice(0, 120);
    const image = imgSrc(img), key = title.toLowerCase().slice(0, 30);
    if (title.length < 6 || CTA.test(title) || pictures.has(image) || names.has(key)) continue;
    pictures.add(image); names.add(key);
    tiles.push({title, price: priceIn(card.textContent), image, ref: refOf(a)});
  }

  // A product: JSON-LD first, then the page's own tags, then its heading, price and biggest picture.
  const ld = [];
  const take = o => {
    if (!o || typeof o !== 'object') return;
    if (Array.isArray(o)) return o.forEach(take);
    const t = o['@type'];
    if (t === 'Product' || (Array.isArray(t) && t.includes('Product'))) ld.push(o);
    if (o['@graph']) take(o['@graph']);
  };
  for (const sc of document.querySelectorAll('script[type="application/ld+json"]')) { try { take(JSON.parse(sc.textContent)); } catch (e) {} }
  // The product's name: a heading the tab's title starts with (an h1 can be a hidden "summary" one), else the h1.
  const docTitle = out.title.toLowerCase();
  const headings = [...document.querySelectorAll('h1,[id*=productTitle],[id*=product-title],[class*=product-title],[class*=productTitle],[itemprop=name]')]
    .filter(h => visible(h) && clean(h.innerText).length >= 4);
  const h1 = headings.find(h => docTitle.includes(clean(h.innerText).toLowerCase().slice(0, 16))) || headings[0];
  const cartButton = buttons().find(b => /aggiungi al carrello|add to (cart|basket|bag)|in den einkaufswagen|ajouter au panier|añadir a la cesta/i.test(textOf(b)));
  const productPath = /\/dp\/|\/gp\/product|\/gp\/aw\/d\/|\/products?\/|\/p\/|\/item\/|\/prodotto/.test(path);
  if (ld.length || meta('og:type') === 'product' || (productPath && h1) || (cartButton && h1 && !query && tiles.length < 6)) {
    const p = ld[0] || {};
    const offer = Array.isArray(p.offers) ? p.offers[0] : (p.offers || {});
    const image = typeof p.image === 'string' ? p.image : Array.isArray(p.image) ? (typeof p.image[0] === 'string' ? p.image[0] : p.image[0] && p.image[0].url) : p.image && p.image.url;
    let best = null, area = 0;
    for (const img of document.images) {
      const r = img.getBoundingClientRect();
      if (!imgSrc(img) || r.width < 100 || r.top + scrollY > vh * 1.5) continue;
      if (r.width * r.height > area) { area = r.width * r.height; best = imgSrc(img); }
    }
    const priced = [...document.querySelectorAll('[itemprop=price],[class*=price],[id*=price]')].filter(visible).map(e => priceIn(e.textContent)).find(Boolean);
    const amount = offer.price || offer.lowPrice || meta('product:price:amount');
    const currency = offer.priceCurrency || meta('product:price:currency');
    const rating = (p.aggregateRating && p.aggregateRating.ratingValue) || ((lower.match(/(\d[.,]\d)\s*(?:su|out of|von|sur|de)\s*5/) || [])[1]);
    out.product = {title: clean(p.name || (h1 && h1.innerText) || meta('og:title') || out.title).slice(0, 140),
                   price: amount ? `${amount}${currency ? ' ' + currency : ''}` : priced || null,
                   image: abs(image) || meta('og:image') || best,
                   rating: rating ? Number(String(rating).replace(',', '.')) || null : null};
  }

  // The cart: how many and the total.
  const badge = document.querySelector('#nav-cart-count,[id*=cart-count],[class*=cart-count],[class*=cartCount],[data-cart-count]');
  const count = badge ? parseInt(clean(badge.innerText || badge.getAttribute('data-cart-count')), 10) : NaN;
  const total = !/cart|basket|carrello|checkout|\/buy|spc|cassa|aw\/c\b/.test(path) ? null : (body.match(new RegExp('(?:subtotale|totale ordine|totale|subtotal|order total|total)[^€$£\\d]{0,40}(' + PRICE.source + ')', 'i')) || [])[1];
  if (!isNaN(count) || total) out.cart = {count: isNaN(count) ? null : count, total: total || null};

  if (out.kind === 'page') {
    if (/ordine (effettuato|confermato|ricevuto)|grazie per (il tuo |l')?ordine|order (placed|confirmed)|thank(s| you) for your order/.test(lower)) out.kind = 'confirmation';
    else if (/checkout|\/buy\/|\/spc\b|gp\/buy|\/cassa|\/pagamento|\/payment/.test(path)) out.kind = 'checkout';
    else if (/\/cart\b|\/basket\b|\/carrello|\/bag\b|gp\/aw\/c\b|gp\/cart/.test(path)) out.kind = 'cart';
    else if (out.product && (ld.length || productPath || meta('og:type') === 'product')) out.kind = 'product';
    else if (tiles.length >= 3 && (query || /search|\/s\b|cerca|ricerca/.test(path))) out.kind = 'results';
    else if (out.product) out.kind = 'product';
  }
  if (out.kind === 'results') out.items = tiles.filter(t => t.price).concat(tiles.filter(t => !t.price)).slice(0, 6);
  if (out.kind !== 'product') out.product = out.kind === 'checkout' || out.kind === 'cart' ? null : out.product;
  document.documentElement.dataset.aideNext = String(next);
  return out;
}
"""


class Browser:
    def __init__(self, root: Path, headed: bool = False):
        self.root = root
        self.headed = headed  # under Xvfb (a DISPLAY): harder for sites to tell from a person's browser
        self._pw = None
        self._ua: str | None = None
        self._contexts: dict[str, object] = {}  # site -> BrowserContext
        self._used: dict[str, float] = {}  # site -> monotonic time its pages were last used
        self._pages: dict[tuple[str, str], object] = {}  # (owner, site) -> Page
        self._current: dict[str, str] = {}  # owner -> site of its current page
        self._acts: dict[str, dict] = {}  # owner -> what the model did last, for the live view
        self._notes: dict[str, str] = {}  # owner -> the model's line for its next action
        self._seq = 0
        self._lock = asyncio.Lock()

    @staticmethod
    def available() -> bool:
        """Playwright is installed and has its Chromium."""
        try:
            from playwright._impl._driver import compute_driver_executable  # noqa: F401
            from playwright.sync_api import sync_playwright  # noqa: F401
        except ImportError:
            return False
        cache = Path.home() / ".cache" / "ms-playwright"
        return any(cache.glob("chromium-*/chrome-linux*/chrome")) or any(cache.glob("chromium-*/chrome-mac*"))

    # -- sites and pages -----------------------------------------------------

    async def _context(self, site: str):
        async with self._lock:
            if site in self._contexts:
                return self._contexts[site]
            if self._pw is None:
                from playwright.async_api import async_playwright
                self._pw = await async_playwright().start()
            if self._ua is None:
                self._ua = _UA.format(v=await self._version())
            profile = self.root / check_site(site)
            profile.mkdir(parents=True, exist_ok=True)
            context = await self._pw.chromium.launch_persistent_context(
                str(profile), channel="chromium", headless=not self.headed, viewport=VIEWPORT, screen=VIEWPORT,
                device_scale_factor=SCALE, is_mobile=True, has_touch=True, user_agent=self._ua, locale="it-IT",
                timezone_id="Europe/Rome", args=["--disable-blink-features=AutomationControlled"],
                ignore_default_args=["--enable-automation"])
            context.set_default_timeout(ACTION_TIMEOUT)
            context.set_default_navigation_timeout(LOAD_TIMEOUT)
            context.on("page", lambda page: self._opened(site, page))
            self._contexts[site] = context
            return context

    async def _version(self) -> str:
        """This Chromium's version, for a user agent that matches the engine."""
        try:
            proc = await asyncio.create_subprocess_exec(self._pw.chromium.executable_path, "--version",
                                                        stdout=asyncio.subprocess.PIPE,
                                                        stderr=asyncio.subprocess.DEVNULL)
            out, _ = await asyncio.wait_for(proc.communicate(), 10)
            if m := re.search(r"(\d+)\.\d+\.\d+\.\d+", out.decode()):
                return f"{m.group(1)}.0.0.0"
        except Exception:
            log.warning("couldn't read Chromium's version", exc_info=True)
        return "141.0.0.0"

    def _opened(self, site: str, page) -> None:
        """A page a click opened (target=_blank): it becomes its opener's owner's current page."""
        async def adopt():
            opener = await page.opener()
            for (owner, s), p in list(self._pages.items()):
                if s == site and p is opener:
                    self._pages[(owner, site)] = page
                    return
        asyncio.get_running_loop().create_task(adopt())

    def page(self, owner: str):
        """The owner's current page, or None."""
        site = self._current.get(owner)
        page = self._pages.get((owner, site)) if site else None
        if page is None or page.is_closed():
            return None
        self._used[site] = time.monotonic()
        return page

    def _page(self, owner: str):
        page = self.page(owner)
        if page is None:
            raise BrowserError("No page is open: open_page first.")
        return page

    def where(self, owner: str) -> dict | None:
        page = self.page(owner)
        if page is None:
            return None
        return {"url": page.url, "site": self._current[owner]}

    def last_action(self, owner: str) -> dict | None:
        """What the model did last on the owner's page, for the live view to show:
        {seq, kind (open, click, type, choose, press, scroll, back), x, y (the element's middle, 0–1 across the
        visible page, or None), label, note (the model's line, or None)}. Also read, find and look (a screenshot).
        Typing into a password field has no label."""
        return self._acts.get(owner)

    def narrate(self, owner: str, note: str | None) -> None:
        """The model's own line for what it does next ("Checking the reviews"), shown with that action."""
        if note and note.strip():
            self._notes[owner] = " ".join(note.split())[:90]

    def _did(self, owner: str, kind: str, label: str | None = None, box: dict | None = None) -> None:
        self._seq += 1
        x = y = None
        if box:
            x = round(min(1.0, max(0.0, (box["x"] + box["width"] / 2) / VIEWPORT["width"])), 3)
            y = round(min(1.0, max(0.0, (box["y"] + box["height"] / 2) / VIEWPORT["height"])), 3)
        self._acts[owner] = {"seq": self._seq, "kind": kind, "x": x, "y": y,
                             "label": (" ".join(label.split())[:60] or None) if label else None,
                             "note": self._notes.pop(owner, None)}

    async def _where_is(self, locator) -> tuple[dict | None, str | None]:
        """The element's box on screen (scrolled into view) and what it says (None for a password field)."""
        try:
            await locator.scroll_into_view_if_needed(timeout=3000)
            box = await locator.bounding_box(timeout=1000)
            label = await locator.evaluate(
                "e => e.type === 'password' ? null : (e.innerText || e.value || e.getAttribute('aria-label')"
                " || e.getAttribute('placeholder') || e.title || e.alt || '').trim()", timeout=1000)
            return box, label
        except Exception:
            return None, None

    async def open(self, owner: str, url: str) -> str:
        url = full_url(url)
        site = site_of(url)
        self._did(owner, "open", urlparse(url).netloc.removeprefix("www.") + urlparse(url).path[:40].rstrip("/"))
        page = self._pages.get((owner, site))
        if page is None or page.is_closed():
            context = await self._context(site)
            blank = [p for p in context.pages if p.url == "about:blank" and p not in self._pages.values()]
            page = blank[0] if blank else await context.new_page()
            self._pages[(owner, site)] = page
        self._current[owner] = site
        self._used[site] = time.monotonic()
        try:
            await page.goto(url, wait_until="domcontentloaded")
        except Exception as e:
            raise BrowserError(f"The page didn't load: {str(e).splitlines()[0][:200]}") from None
        await self._settle(page)
        return await self._heading(page)

    async def close(self, owner: str) -> None:
        for key in [k for k in self._pages if k[0] == owner]:
            page = self._pages.pop(key)
            try:
                await page.close()
            except Exception:
                pass
        self._current.pop(owner, None)
        self._acts.pop(owner, None)
        self._notes.pop(owner, None)

    async def prune(self) -> None:
        """Close the browsers of sites with no page in use for IDLE."""
        now = time.monotonic()
        for site, context in list(self._contexts.items()):
            busy = any(s == site and not p.is_closed() for (_, s), p in self._pages.items())
            if not busy and now - self._used.get(site, 0) > IDLE:
                self._contexts.pop(site, None)
                try:
                    await context.close()
                except Exception:
                    pass

    def sites(self) -> list[dict]:
        """The sites with a profile (the user may be logged in there), most recently used first."""
        if not self.root.exists():
            return []
        out = []
        for d in self.root.iterdir():
            if d.is_dir() and _SITE.match(d.name):
                used = max((f.stat().st_mtime for f in d.glob("Default/*") if f.is_file()), default=d.stat().st_mtime)
                out.append({"site": d.name, "used_at": datetime.fromtimestamp(used, timezone.utc).isoformat(),
                            "open": d.name in self._contexts})
        return sorted(out, key=lambda s: s["used_at"], reverse=True)

    async def forget(self, site: str) -> bool:
        """Log out of a site for good: close it and delete its profile (cookies, saved logins)."""
        check_site(site)
        for key in [k for k in self._pages if k[1] == site]:
            self._pages.pop(key, None)
        for owner in [o for o, s in self._current.items() if s == site]:
            self._current.pop(owner)
        if context := self._contexts.pop(site, None):
            try:
                await context.close()
            except Exception:
                pass
        profile = self.root / site
        if profile.exists():
            shutil.rmtree(profile)
            return True
        return False

    async def stop(self) -> None:
        for context in list(self._contexts.values()):
            try:
                await context.close()
            except Exception:
                pass
        self._contexts.clear()
        if self._pw is not None:
            await self._pw.stop()
            self._pw = None

    # -- what the model does -------------------------------------------------

    async def _settle(self, page) -> None:
        try:
            await page.wait_for_load_state("domcontentloaded", timeout=LOAD_TIMEOUT)
        except Exception:
            pass
        await asyncio.sleep(SETTLE)

    async def _heading(self, page) -> str:
        try:
            title = await page.title()
        except Exception:
            title = ""
        return f"{title or '(no title)'} — {page.url}"

    async def read(self, owner: str, everything: bool = False) -> str:
        page = self._page(owner)
        self._did(owner, "read")
        try:
            got = await page.evaluate(_READ_JS, {"everything": everything, "limit": READ_LIMIT})
        except Exception as e:
            raise BrowserError(f"Couldn't read the page (it may still be loading): {str(e)[:160]}") from None
        head = f"Page: {got['title'] or '(no title)'} — {got['url']}\nScreen {got['at']} of {got['screens']}"
        tail = "\n(more below: scroll down, or find_on_page)" if got["more"] else ""
        return head + "\n" + "\n".join(got["lines"]) + tail

    async def find(self, owner: str, text: str) -> str:
        self._did(owner, "find", text)
        found = await self._page(owner).evaluate(_FIND_JS, text)
        return "\n".join(found) if found else f"Nothing on this page says {text!r}."

    def _ref(self, page, ref: str):
        if not re.fullmatch(r"\d{1,6}", str(ref)):
            raise BrowserError(f"{ref!r} isn't a ref: use the number in brackets from read_page")
        return page.locator(f'[data-aide-ref="{ref}"]').first

    async def inspect(self, owner: str, ref: str) -> dict:
        """What the element is: {tag, type, text, sensitive}. BrowserError when the page has no such ref now."""
        locator = self._ref(self._page(owner), ref)
        if await locator.count() == 0:
            raise BrowserError(f"There's no [{ref}] on the page now: read_page again.")
        return await locator.evaluate(_INSPECT_JS)

    async def focused(self, owner: str) -> dict:
        """inspect() for the focused element (what Enter would act on)."""
        return await self._page(owner).evaluate(f"() => ({_INSPECT_JS})(document.activeElement || document.body)")

    async def click(self, owner: str, ref: str) -> str:
        page = self._page(owner)
        locator = self._ref(page, ref)
        if await locator.count() == 0:
            raise BrowserError(f"There's no [{ref}] on the page now: read_page again.")
        box, label = await self._where_is(locator)
        self._did(owner, "click", label, box)
        try:
            await locator.scroll_into_view_if_needed(timeout=3000)
            await locator.click()
        except Exception as e:
            raise BrowserError(f"Couldn't click [{ref}]: {str(e).splitlines()[0][:200]}") from None
        await self._settle(page)
        return "Clicked. Now: " + await self._heading(self._page(owner))

    async def fill(self, owner: str, ref: str, text: str, submit: bool = False) -> str:
        page = self._page(owner)
        locator = self._ref(page, ref)
        if await locator.count() == 0:
            raise BrowserError(f"There's no [{ref}] on the page now: read_page again.")
        box, label = await self._where_is(locator)
        self._did(owner, "type", None if label is None else text, box)  # never what goes in a password field
        try:
            await locator.fill(text)
            if submit:
                await locator.press("Enter")
        except Exception as e:
            raise BrowserError(f"Couldn't type in [{ref}]: {str(e).splitlines()[0][:200]}") from None
        if submit:
            await self._settle(page)
            return "Typed and pressed Enter. Now: " + await self._heading(self._page(owner))
        return "Typed."

    async def choose(self, owner: str, ref: str, option: str) -> str:
        locator = self._ref(self._page(owner), ref)
        box, _ = await self._where_is(locator)
        self._did(owner, "choose", option, box)
        try:
            await locator.select_option(label=option)
        except Exception:
            try:
                await locator.select_option(value=option)
            except Exception as e:
                raise BrowserError(f"Couldn't choose {option!r} in [{ref}]: {str(e).splitlines()[0][:160]}") from None
        await asyncio.sleep(SETTLE)
        return f"Chose {option}."

    async def press(self, owner: str, key: str) -> str:
        page = self._page(owner)
        self._did(owner, "press", key)
        await page.keyboard.press(key)
        await self._settle(page)
        return f"Pressed {key}. Now: " + await self._heading(self._page(owner))

    async def scroll(self, owner: str, direction: str) -> str:
        page = self._page(owner)
        self._did(owner, "scroll", direction)
        await page.evaluate("d => window.scrollBy(0, d * window.innerHeight * 0.8)", 1 if direction == "down" else -1)
        await asyncio.sleep(0.4)
        return f"Scrolled {direction}."

    async def back(self, owner: str) -> str:
        page = self._page(owner)
        self._did(owner, "back")
        try:
            await page.go_back(wait_until="domcontentloaded")
        except Exception as e:
            raise BrowserError(f"Couldn't go back: {str(e).splitlines()[0][:160]}") from None
        await self._settle(page)
        return "Went back. Now: " + await self._heading(page)

    async def images(self, owner: str) -> list[dict]:
        """The page's pictures by link: [{path, src, alt}] (path as read() writes it; None for an unlinked one)."""
        try:
            return await self._page(owner).evaluate(_IMAGES_JS)
        except BrowserError:
            raise
        except Exception:
            return []

    async def main_image(self, owner: str, url: str) -> str | None:
        """Opens a product page and returns its picture's URL, or None."""
        await self.open(owner, url)
        try:
            return await self._page(owner).evaluate(_MAIN_IMAGE_JS)
        except Exception:
            return None

    async def screenshot(self, owner: str, sharp: bool = False) -> bytes:
        """The visible part of the page as a JPEG: CSS pixels for the model, device pixels with `sharp`."""
        if not sharp:
            self._did(owner, "look")
        return await self._page(owner).screenshot(type="jpeg", quality=70 if sharp else 60,
                                                  scale="device" if sharp else "css")

    async def text(self, owner: str) -> str:
        """All the page's text, for checking a total before a confirmed click."""
        return await self._page(owner).evaluate("() => document.body ? document.body.innerText : ''")

    # -- the user's live view ------------------------------------------------

    async def scene(self, owner: str) -> dict | None:
        """What kind of page the owner's is and what's on it (_SCENE_JS), or None with no page."""
        page = self.page(owner)
        if page is None:
            return None
        try:
            return await page.evaluate(_SCENE_JS)
        except Exception:
            return None  # mid-navigation: next time

    async def crop(self, owner: str, ref: str) -> tuple[bytes, dict] | None:
        """A JPEG of one element (a CAPTCHA) and its box on the visible page (0–1), or None."""
        locator = self._ref(self._page(owner), ref)
        try:
            await locator.scroll_into_view_if_needed(timeout=2000)
            box = await locator.bounding_box(timeout=1000)
            shot = await locator.screenshot(type="jpeg", quality=80, timeout=3000)
        except Exception:
            return None
        if not box:
            return None
        w, h = VIEWPORT["width"], VIEWPORT["height"]
        return shot, {"x": round(box["x"] / w, 4), "y": round(box["y"] / h, 4),
                      "width": round(box["width"] / w, 4), "height": round(box["height"] / h, 4)}

    async def put(self, owner: str, ref: str, text: str) -> None:
        """The user's text into a field (from the app's own login screen). Never recorded or logged."""
        locator = self._ref(self._page(owner), ref)
        await locator.fill(text, timeout=ACTION_TIMEOUT)

    async def press_ref(self, owner: str, ref: str, tick: str | None = None) -> None:
        """The user's press on a button or choice (`tick`: a "stay logged in" box to tick first)."""
        page = self._page(owner)
        if tick:
            try:
                await self._ref(page, tick).check(timeout=2000)
            except Exception:
                pass
        await self._ref(page, ref).click(timeout=ACTION_TIMEOUT)
        await self._settle(page)

    async def screencast(self, owner: str, on_frame: Callable[[str, int, int], None]) -> Callable[[], Awaitable]:
        """Start sending the owner's page as JPEG frames (base64, width, height) as it changes. Returns `stop`."""
        page = self._page(owner)
        cdp = await page.context.new_cdp_session(page)

        async def ack(session_id: int) -> None:
            try:
                await cdp.send("Page.screencastFrameAck", {"sessionId": session_id})
            except Exception:
                pass

        def frame(params: dict) -> None:
            meta = params.get("metadata", {})
            on_frame(params["data"], int(meta.get("deviceWidth", VIEWPORT["width"]) * SCALE),
                     int(meta.get("deviceHeight", VIEWPORT["height"]) * SCALE))
            asyncio.get_running_loop().create_task(ack(params["sessionId"]))

        cdp.on("Page.screencastFrame", frame)
        await cdp.send("Page.startScreencast", {"format": "jpeg", "quality": 60,
                                                "maxWidth": VIEWPORT["width"] * SCALE,
                                                "maxHeight": VIEWPORT["height"] * SCALE})
        # The screencast only sends when something changes: the page as it is now comes first.
        shot = await page.screenshot(type="jpeg", quality=60)
        on_frame(base64.b64encode(shot).decode(), VIEWPORT["width"] * SCALE, VIEWPORT["height"] * SCALE)

        async def stop() -> None:
            try:
                await cdp.send("Page.stopScreencast")
                await cdp.detach()
            except Exception:
                pass
        return stop

    async def tap(self, owner: str, x: float, y: float) -> None:
        """A tap at (x, y), each 0–1 across the visible page."""
        page = self._page(owner)
        await page.touchscreen.tap(max(0.0, min(1.0, x)) * VIEWPORT["width"],
                                   max(0.0, min(1.0, y)) * VIEWPORT["height"])

    async def wheel(self, owner: str, x: float, y: float, dy: float) -> None:
        """Scroll at (x, y) by dy screen heights (positive: down)."""
        page = self._page(owner)
        await page.mouse.move(x * VIEWPORT["width"], y * VIEWPORT["height"])
        await page.mouse.wheel(0, dy * VIEWPORT["height"])

    async def type_text(self, owner: str, text: str) -> None:
        await self._page(owner).keyboard.type(text, delay=15)

    async def key(self, owner: str, name: str) -> None:
        await self._page(owner).keyboard.press(name)

    async def focus(self, owner: str) -> dict:
        try:
            return await self._page(owner).evaluate(_FOCUS_JS)
        except Exception:
            return {"field": None}
