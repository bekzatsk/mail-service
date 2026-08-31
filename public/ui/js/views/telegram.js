import { clientApi, selectedClient } from '../store.js';
import { navigate, currentRoute } from '../router.js';
import { el, emptyState, toastError, skeletonRows } from '../ui.js';

import { renderBots } from './telegram/bots.js';
import { renderCommands } from './telegram/commands.js';
import { renderChats } from './telegram/chats.js';
import { renderMessages } from './telegram/messages.js';

const PANELS = [
  { id: 'bots',     label: 'Bots',     render: renderBots },
  { id: 'commands', label: 'Commands', render: renderCommands },
  { id: 'chats',    label: 'Chats',    render: renderChats },
  { id: 'messages', label: 'Messages', render: renderMessages }
];

function noClientScoped() {
  return el('section', { class: 'view' },
    el('header', { class: 'view__head' },
      el('div', {},
        el('span', { class: 'eyebrow', text: 'Gateway' }),
        el('h1', { class: 'view__title', text: 'Telegram' })
      )
    ),
    emptyState(
      'No client selected',
      'Telegram bots belong to a client, not to an organization. Pick a client in the header to manage its bots.',
      el('button', { class: 'btn btn--primary', type: 'button', text: 'Go to clients', onclick: () => navigate('clients') })
    )
  );
}

export async function render() {
  const current = selectedClient();
  const api = clientApi();
  if (!current || !api) return noClientScoped();

  const requested = currentRoute()?.params?.[0];
  let activeId = PANELS.some((panel) => panel.id === requested) ? requested : 'bots';

  const body = el('div');
  const tabs = el('div', { class: 'tabs', role: 'tablist' });

  // Bots are the shared dependency of every other panel, so they live here.
  let bots = [];

  const reloadBots = async () => {
    const payload = await api.bots();
    bots = payload.bots || [];
    return bots;
  };

  const paintTabs = () => {
    tabs.replaceChildren(...PANELS.map((panel) => el('button', {
      class: 'tab', type: 'button', role: 'tab',
      'aria-selected': String(panel.id === activeId),
      text: panel.label,
      onclick: () => { activeId = panel.id; navigate(`telegram/${panel.id}`, { replace: true }); paintTabs(); paintPanel(); }
    })));
  };

  const paintPanel = async () => {
    body.replaceChildren(skeletonRows(4));
    const panel = PANELS.find((entry) => entry.id === activeId);
    try {
      body.replaceChildren(await panel.render({ api, bots, reloadBots, refresh: paintPanel }));
    } catch (error) {
      body.replaceChildren(emptyState('Could not load', error.message));
      toastError(error);
    }
  };

  try {
    await reloadBots();
  } catch (error) {
    toastError(error);
  }

  paintTabs();
  await paintPanel();

  return el('section', { class: 'view' },
    el('header', { class: 'view__head' },
      el('div', {},
        el('span', { class: 'eyebrow', text: 'Gateway' }),
        el('h1', { class: 'view__title', text: 'Telegram' }),
        el('p', { class: 'view__sub' }, 'Bots owned by ',
          el('span', { class: 'mono', text: current.fromAddress }),
          '. Each enabled bot runs a long-poll listener inside the service process.')
      )
    ),
    tabs,
    body
  );
}
