// DOM helpers, toasts and modals.
// Text always goes through textContent — no innerHTML anywhere in this file,
// so API-sourced strings can never become markup.

export function el(tag, props, ...children) {
  const node = document.createElement(tag);

  for (const [key, value] of Object.entries(props || {})) {
    if (value === null || value === undefined || value === false) continue;

    if (key === 'class') node.className = value;
    else if (key === 'text') node.textContent = String(value);
    else if (key === 'dataset') Object.assign(node.dataset, value);
    else if (key === 'style') Object.assign(node.style, value);
    else if (key.startsWith('on') && typeof value === 'function') {
      node.addEventListener(key.slice(2).toLowerCase(), value);
    } else if (value === true) node.setAttribute(key, '');
    else node.setAttribute(key, String(value));
  }

  appendChildren(node, children);
  return node;
}

function appendChildren(node, children) {
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
}

export function clear(node) {
  node.replaceChildren();
  return node;
}

export function frag(...children) {
  const fragment = document.createDocumentFragment();
  appendChildren(fragment, children);
  return fragment;
}

// ── Formatting ──────────────────────────────────────────────────────

export function formatDate(value) {
  if (!value) return '—';
  const date = new Date(String(value).replace(' ', 'T'));
  if (Number.isNaN(date.getTime())) return String(value);
  return date.toLocaleString(undefined, {
    year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit'
  });
}

const RELATIVE_UNITS = [
  ['year', 31536000], ['month', 2592000], ['day', 86400],
  ['hour', 3600], ['minute', 60], ['second', 1]
];

export function relativeTime(value) {
  if (!value) return '—';
  const date = new Date(String(value).replace(' ', 'T'));
  if (Number.isNaN(date.getTime())) return String(value);

  const seconds = Math.round((date.getTime() - Date.now()) / 1000);
  const formatter = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });
  for (const [unit, size] of RELATIVE_UNITS) {
    if (Math.abs(seconds) >= size || unit === 'second') {
      return formatter.format(Math.round(seconds / size), unit);
    }
  }
  return '—';
}

export function formatNumber(value) {
  return new Intl.NumberFormat().format(Number(value) || 0);
}

export function maskSecret(secret) {
  const text = String(secret || '');
  if (text.length <= 10) return '•'.repeat(text.length);
  return `${text.slice(0, 4)}${'•'.repeat(8)}${text.slice(-4)}`;
}

export function listToText(value) {
  if (Array.isArray(value)) return value.join(', ');
  return value ? String(value) : '';
}

// ── Toasts ──────────────────────────────────────────────────────────

const toastHost = el('div', { class: 'toasts', role: 'status', 'aria-live': 'polite' });
document.body.append(toastHost);

export function toast(message, tone = 'info', timeout = 4200) {
  const node = el('div', { class: `toast toast--${tone === 'error' ? 'bad' : tone === 'success' ? 'ok' : 'info'}` },
    el('span', { class: 'toast__text', text: message })
  );
  toastHost.append(node);

  const remove = () => {
    node.classList.add('toast--out');
    node.addEventListener('animationend', () => node.remove(), { once: true });
  };
  const timer = setTimeout(remove, timeout);
  node.addEventListener('click', () => { clearTimeout(timer); remove(); });
  return node;
}

export function toastError(error) {
  toast(error?.message || 'Unexpected error', 'error', 6500);
  if (!(error?.status)) console.error(error);
}

// ── Clipboard ───────────────────────────────────────────────────────

export async function copyToClipboard(text, label = 'Copied') {
  try {
    await navigator.clipboard.writeText(text);
    toast(label, 'success', 1800);
  } catch {
    toast('Clipboard blocked — select the value and copy manually', 'error');
  }
}

// ── Modal ───────────────────────────────────────────────────────────

/**
 * Opens a modal. `render({ close })` returns the body content; `footer`
 * receives the same handle. Resolves once the modal closes.
 */
export function openModal({ title, render, footer, wide = false }) {
  return new Promise((resolve) => {
    let settled;

    const close = (value) => {
      settled = value;
      backdrop.remove();
      document.removeEventListener('keydown', onKeydown);
      resolve(settled);
    };

    const onKeydown = (event) => {
      if (event.key === 'Escape') close(undefined);
    };

    const handle = { close };

    const modal = el('div', { class: `modal${wide ? ' modal--wide' : ''}`, role: 'dialog', 'aria-modal': 'true' },
      el('header', { class: 'modal__head' },
        el('h2', { class: 'modal__title', text: title }),
        el('button', { class: 'btn btn--ghost btn--sm modal__close', type: 'button',
          'aria-label': 'Close', onclick: () => close(undefined), text: '✕' })
      ),
      el('div', { class: 'modal__body' }, render(handle)),
      footer ? el('footer', { class: 'modal__foot' }, footer(handle)) : null
    );

    const backdrop = el('div', { class: 'modal-backdrop', onclick: (event) => {
      if (event.target === backdrop) close(undefined);
    } }, modal);

    document.addEventListener('keydown', onKeydown);
    document.body.append(backdrop);

    const focusable = modal.querySelector('input, select, textarea, button.btn--primary');
    focusable?.focus();
  });
}

/** Destructive-action confirmation. Resolves true only on explicit confirm. */
export function confirmAction({ title, message, confirmLabel = 'Delete', tone = 'danger' }) {
  return openModal({
    title,
    render: () => el('p', { class: 'mid', text: message }),
    footer: ({ close }) => [
      el('button', { class: 'btn', type: 'button', text: 'Cancel', onclick: () => close(false) }),
      el('button', {
        class: `btn ${tone === 'danger' ? 'btn--danger' : 'btn--primary'}`,
        type: 'button',
        text: confirmLabel,
        onclick: () => close(true)
      })
    ]
  }).then((value) => value === true);
}

// ── Building blocks ─────────────────────────────────────────────────

export function field(label, control, hint) {
  return el('label', { class: 'field' },
    el('span', { class: 'field__label', text: label }),
    control,
    hint ? el('span', { class: 'field__hint', text: hint }) : null
  );
}

export function badge(text, tone = 'mute') {
  return el('span', { class: `badge badge--${tone}`, text });
}

export function statusBadge(status) {
  const tone = status === 'sent' || status === 'received' ? 'ok'
    : status === 'failed' ? 'bad'
    : status === 'queued' ? 'warn' : 'mute';
  return badge(status || 'unknown', tone);
}

export function emptyState(title, note, action) {
  return el('div', { class: 'empty' },
    el('p', { class: 'empty__title', text: title }),
    note ? el('p', { text: note }) : null,
    action || null
  );
}

export function skeletonRows(count = 4) {
  return el('div', { class: 'card' },
    el('div', { class: 'card__body', style: { display: 'grid', gap: '0.75rem' } },
      ...Array.from({ length: count }, (_, index) =>
        el('div', { class: 'skeleton', style: { width: `${95 - index * 12}%` } }))
    )
  );
}

/** A masked secret with reveal + copy affordances. */
export function secretChip(value, { revealed = false } = {}) {
  let visible = revealed;

  const text = el('span', { class: 'keychip__value mono', text: visible ? value : maskSecret(value) });
  const toggle = el('button', {
    class: 'btn btn--ghost btn--sm', type: 'button',
    text: visible ? 'Hide' : 'Show',
    onclick: () => {
      visible = !visible;
      text.textContent = visible ? value : maskSecret(value);
      text.classList.toggle('keychip__value--revealed', visible);
      toggle.textContent = visible ? 'Hide' : 'Show';
    }
  });

  return el('span', { class: 'keychip' },
    text,
    toggle,
    el('button', {
      class: 'btn btn--ghost btn--sm', type: 'button', text: 'Copy',
      onclick: () => copyToClipboard(value, 'Key copied to clipboard')
    })
  );
}

/** Runs an async action while disabling the button and showing a spinner. */
export function withBusy(button, action) {
  const original = button.textContent;
  button.disabled = true;
  clear(button).append(el('span', { class: 'spinner' }), document.createTextNode(' Working'));

  return Promise.resolve()
    .then(action)
    .finally(() => {
      button.disabled = false;
      clear(button).append(document.createTextNode(original));
    });
}
