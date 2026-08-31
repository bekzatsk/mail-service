// Application chrome: lock screen, sidebar, header, and view mounting.

import {
  getState, subscribe, saveMasterKey, clearMasterKey, isAuthenticated,
  refresh, selectClient, selectedClient
} from './store.js';
import { admin } from './api.js';
import { defineRoute, setNotFound, startRouter, navigate, currentRoute, parseHash } from './router.js';
import { el, clear, toast, toastError, formatNumber, emptyState, skeletonRows, withBusy } from './ui.js';

import { render as renderDashboard } from './views/dashboard.js';
import { render as renderOrganizations } from './views/organizations.js';
import { render as renderClients } from './views/clients.js';
import { render as renderLogs } from './views/logs.js';
import { render as renderTelegram } from './views/telegram.js';
import { render as renderSend } from './views/send.js';

const NAV = [
  { id: 'dashboard',     label: 'Dashboard',    icon: '◈', render: renderDashboard },
  { id: 'organizations', label: 'Organizations', icon: '⬢', render: renderOrganizations, count: (s) => s.organizations.length },
  { id: 'clients',       label: 'Clients & keys', icon: '◆', render: renderClients, count: (s) => s.clients.length },
  { id: 'logs',          label: 'Mail logs',    icon: '≡', render: renderLogs },
  { id: 'telegram',      label: 'Telegram',     icon: '✈', render: renderTelegram },
  { id: 'send',          label: 'Send test',    icon: '↗', render: renderSend }
];

const root = document.getElementById('root');

// ── Lock screen ─────────────────────────────────────────────────────

function renderLock() {
  const keyInput = el('input', {
    class: 'input input--mono', type: 'password', autocomplete: 'current-password',
    placeholder: '64-character master key', required: true
  });
  const remember = el('input', { type: 'checkbox' });
  const error = el('p', { class: 'field__error' });
  const submit = el('button', { class: 'btn btn--primary btn--block', type: 'submit', text: 'Unlock console' });

  const onSubmit = (event) => {
    event.preventDefault();
    const key = keyInput.value.trim();
    if (!key) {
      error.textContent = 'Enter the master key.';
      keyInput.focus();
      return;
    }
    error.textContent = '';

    withBusy(submit, async () => {
      try {
        // Verify before persisting, so a wrong key is never stored.
        await admin(key).verify();
        saveMasterKey(key, remember.checked);
        await boot();
      } catch (failure) {
        error.textContent = failure.status === 403
          ? 'That key was rejected by the server.'
          : failure.message;
        keyInput.focus();
        keyInput.select();
      }
    });
  };

  const form = el('form', { class: 'card', onsubmit: onSubmit },
    el('div', { class: 'card__body', style: { display: 'grid', gap: 'var(--space-4)' } },
      el('label', { class: 'field' },
        el('span', { class: 'field__label', text: 'Master API key' }),
        keyInput,
        el('span', { class: 'field__hint', text: 'The MASTER_API_KEY from the service .env file.' })
      ),
      el('label', { class: 'check' }, remember,
        el('span', { text: 'Keep me signed in on this device (stores the key in localStorage)' })),
      error
    ),
    el('div', { class: 'card__foot', style: { justifyContent: 'stretch' } }, submit)
  );

  return el('main', { class: 'lock' },
    el('div', { class: 'lock__panel' },
      el('div', {},
        el('span', { class: 'eyebrow', text: 'mail-service' }),
        el('h1', { class: 'lock__mark' }, 'MAIL', el('span', { text: '\u00b7' }), 'SVC')
      ),
      el('p', { class: 'lock__note', text: 'Operator console for organizations, client API keys, SMTP delivery and Telegram bots.' }),
      form,
      el('p', { class: 'callout', text: 'The master key grants full administrative access, including reading every client API key. Only unlock this console on a machine you trust.' })
    )
  );
}

// ── Chrome ──────────────────────────────────────────────────────────

function renderSidebar() {
  const nav = el('nav', { class: 'nav', 'aria-label': 'Main navigation' });

  const paint = (state) => {
    // parseHash() rather than currentRoute(): this listener can run before the
    // router's own hashchange handler has refreshed its cached route.
    const active = parseHash().name;
    nav.replaceChildren(...NAV.map((item) => {
      const count = item.count ? item.count(state) : null;
      return el('a', {
        class: 'nav__item', href: `#/${item.id}`,
        'aria-current': item.id === active ? 'page' : null
      },
        el('span', { class: 'nav__icon', 'aria-hidden': 'true', text: item.icon }),
        el('span', { text: item.label }),
        count === null ? null : el('span', { class: 'nav__count', text: formatNumber(count) })
      );
    }));
  };

  paint(getState());
  subscribe(paint);
  window.addEventListener('hashchange', () => paint(getState()));

  return el('aside', { class: 'sidebar' },
    el('div', { class: 'brand' },
      el('span', { class: 'brand__mark', 'aria-hidden': 'true', text: 'M' }),
      el('span', { class: 'brand__name', text: 'mail·svc' })
    ),
    nav,
    el('div', { class: 'sidebar__foot' },
      el('span', { class: 'eyebrow', text: 'Session' }),
      el('button', {
        class: 'btn btn--block btn--sm', type: 'button', text: 'Lock console',
        onclick: () => { clearMasterKey(); boot(); }
      })
    )
  );
}

function renderScopeSwitcher() {
  const select = el('select', { class: 'select', 'aria-label': 'Client scope' });

  const paint = (state) => {
    const current = selectedClient();
    select.replaceChildren(
      ...(state.clients.length
        ? state.clients.map((entry) => el('option', {
            value: entry.id,
            selected: current && entry.id === current.id,
            text: `${entry.fromAddress} · ${entry.organizationName}`
          }))
        : [el('option', { value: '', text: 'No clients yet' })])
    );
  };

  select.addEventListener('change', () => {
    selectClient(select.value);
    const route = currentRoute()?.name;
    if (route === 'telegram' || route === 'send') mountRoute();
  });

  paint(getState());
  subscribe(paint);

  return el('div', { class: 'scope' },
    el('span', { class: 'scope__label', text: 'Scope' }),
    select
  );
}

function renderHeader() {
  const crumbs = el('div', { class: 'header__crumbs' });

  const paint = () => {
    const active = NAV.find((item) => item.id === parseHash().name);
    crumbs.replaceChildren(
      el('span', { text: 'console' }),
      el('span', { text: '/' }),
      el('strong', { text: active ? active.label.toLowerCase() : 'unknown' })
    );
  };

  paint();
  window.addEventListener('hashchange', paint);

  const reloadButton = el('button', {
    class: 'btn btn--sm', type: 'button', text: 'Refresh',
    onclick: (event) => withBusy(event.currentTarget, async () => {
      try {
        await refresh();
        mountRoute();
        toast('Reloaded', 'success', 1500);
      } catch (error) {
        toastError(error);
      }
    })
  });

  return el('header', { class: 'header' },
    crumbs,
    el('span', { class: 'header__spacer' }),
    renderScopeSwitcher(),
    reloadButton
  );
}

// ── Mounting ────────────────────────────────────────────────────────

let viewHost = null;

async function mountView(handler) {
  if (!viewHost) return;
  viewHost.replaceChildren(el('div', { class: 'view' }, skeletonRows(5)));

  try {
    viewHost.replaceChildren(await handler());
  } catch (error) {
    viewHost.replaceChildren(el('section', { class: 'view' },
      emptyState('Could not load this view', error.message,
        el('button', { class: 'btn', type: 'button', text: 'Retry', onclick: () => mountView(handler) }))
    ));
    toastError(error);
  }
}

function mountRoute() {
  const route = currentRoute();
  const item = NAV.find((entry) => entry.id === route?.name);
  mountView(item ? item.render : () => Promise.resolve(
    el('section', { class: 'view' }, emptyState('Unknown page', `No view is registered for “${route?.name}”.`,
      el('button', { class: 'btn', type: 'button', text: 'Back to dashboard', onclick: () => navigate('dashboard') })))
  ));
}

function renderShell() {
  viewHost = el('div');

  NAV.forEach((item) => defineRoute(item.id, item.render));
  setNotFound(null);

  const shell = el('div', { class: 'shell' },
    renderSidebar(),
    el('main', { class: 'main' }, renderHeader(), viewHost)
  );

  clear(root).append(shell);
  startRouter(() => mountRoute());
}

// ── Boot ────────────────────────────────────────────────────────────

export async function boot() {
  if (!isAuthenticated()) {
    viewHost = null;
    clear(root).append(renderLock());
    return;
  }

  clear(root).append(el('main', { class: 'view' }, skeletonRows(6)));

  try {
    await refresh();
    renderShell();
  } catch (error) {
    if (error.status === 401 || error.status === 403) {
      clearMasterKey();
      clear(root).append(renderLock());
      toast('Session rejected — sign in again', 'error');
      return;
    }
    clear(root).append(el('main', { class: 'view' },
      emptyState('Cannot reach the service', error.message,
        el('button', { class: 'btn btn--primary', type: 'button', text: 'Retry', onclick: () => boot() }))
    ));
  }
}
