import {
  el, field, openModal, confirmAction, toast, toastError,
  badge, formatDate, emptyState, withBusy
} from '../../ui.js';

const CHAT_TYPES = ['private', 'group', 'supergroup', 'channel'];
const ROUTE_PATTERN = /^[a-z0-9][a-z0-9_-]{0,63}$/;

// A route is the name a calling project sends instead of a chat id, so the
// group behind "errors" can change here without a deploy on their side.
async function openRouteDialog(api, chat, onDone) {
  const route = el('input', {
    class: 'input input--mono', type: 'text', value: chat.routeName || '',
    placeholder: 'errors'
  });
  const error = el('p', { class: 'field__error' });

  await openModal({
    title: chat.routeName ? `Route for ${chat.title || chat.chatId}` : `Name a route for ${chat.title || chat.chatId}`,
    render: () => el('div', { class: 'form-grid' },
      field('Route name', route, 'Lowercase letters, digits, dash and underscore. Leave empty to remove the route.'),
      el('p', { class: 'callout', text: 'Callers send {"route": "<name>", "text": "..."} and never hold a chat id. '
        + 'Point the name at a different group here and every caller follows, with no change on their side.' }),
      error
    ),
    footer: ({ close }) => [
      el('button', { class: 'btn', type: 'button', text: 'Cancel', onclick: () => close(false) }),
      el('button', {
        class: 'btn btn--primary', type: 'button', text: 'Save route',
        onclick: (event) => {
          const value = route.value.trim().toLowerCase();
          if (value && !ROUTE_PATTERN.test(value)) {
            error.textContent = 'Use 1-64 lowercase letters, digits, dash or underscore.';
            return;
          }
          error.textContent = '';
          withBusy(event.currentTarget, async () => {
            try {
              await api.updateChat(chat.id, { routeName: value });
              toast(value ? `Route "${value}" now reaches this chat` : 'Route removed', 'success');
              close(true);
              await onDone();
            } catch (failure) {
              toastError(failure);
            }
          });
        }
      })
    ]
  });
}

async function openCreateDialog(api, bots, defaultBotId, onDone) {
  const bot = el('select', { class: 'select' },
    bots.map((entry) => el('option', {
      value: entry.id,
      selected: String(entry.id) === String(defaultBotId),
      text: entry.botUsername ? `${entry.name} · @${entry.botUsername}` : entry.name
    }))
  );
  const chatId = el('input', { class: 'input input--mono', type: 'text', placeholder: '-1001234567890' });
  const title = el('input', { class: 'input', type: 'text', placeholder: 'Ops alerts' });
  const chatType = el('select', { class: 'select' },
    CHAT_TYPES.map((type) => el('option', { value: type, text: type }))
  );
  const routeName = el('input', { class: 'input input--mono', type: 'text', placeholder: 'errors' });
  const error = el('p', { class: 'field__error' });

  await openModal({
    title: 'Register a chat',
    render: () => el('div', { class: 'form-grid' },
      field('Bot', bot),
      field('Chat ID', chatId, 'Negative for groups and channels. The bot must already be a member.'),
      field('Title', title, 'Label used in this panel only.'),
      field('Type', chatType),
      field('Route name', routeName, 'Optional. The name callers send instead of this chat id.'),
      error
    ),
    footer: ({ close }) => [
      el('button', { class: 'btn', type: 'button', text: 'Cancel', onclick: () => close(false) }),
      el('button', {
        class: 'btn btn--primary', type: 'button', text: 'Register',
        onclick: (event) => {
          const value = chatId.value.trim();
          if (!/^-?\d+$/.test(value)) { error.textContent = 'Chat ID must be a number.'; return; }
          error.textContent = '';

          withBusy(event.currentTarget, async () => {
            try {
              const routeValue = routeName.value.trim().toLowerCase();
              if (routeValue && !ROUTE_PATTERN.test(routeValue)) {
                error.textContent = 'Route name: 1-64 lowercase letters, digits, dash or underscore.';
                return;
              }
              await api.createChat({
                botId: Number(bot.value),
                chatId: Number(value),
                title: title.value.trim() || null,
                chatType: chatType.value,
                routeName: routeValue || null
              });
              toast('Chat registered', 'success');
              close(true);
              await onDone();
            } catch (failure) {
              toastError(failure);
            }
          });
        }
      })
    ]
  });
}

async function openSendDialog(api, chat, bots, onDone) {
  const bot = bots.find((entry) => entry.id === chat.botId);
  const text = el('textarea', { class: 'textarea', placeholder: 'Message text…' });
  const parseMode = el('select', { class: 'select' },
    el('option', { value: '', text: 'Plain text' }),
    el('option', { value: 'HTML', text: 'HTML' }),
    el('option', { value: 'MarkdownV2', text: 'MarkdownV2' })
  );
  const error = el('p', { class: 'field__error' });

  await openModal({
    title: `Send to ${chat.title || chat.chatId}`,
    render: () => el('div', { class: 'form-grid' },
      el('p', { class: 'field__hint', text: bot ? `Sent as ${bot.name}${bot.botUsername ? ` (@${bot.botUsername})` : ''}.` : '' }),
      field('Message', text),
      field('Parse mode', parseMode),
      error
    ),
    footer: ({ close }) => [
      el('button', { class: 'btn', type: 'button', text: 'Cancel', onclick: () => close(false) }),
      el('button', {
        class: 'btn btn--primary', type: 'button', text: 'Send',
        onclick: (event) => {
          if (!text.value.trim()) { error.textContent = 'Message text is required.'; return; }
          error.textContent = '';

          withBusy(event.currentTarget, async () => {
            try {
              const payload = { botId: chat.botId, chatId: chat.chatId, text: text.value };
              if (parseMode.value) payload.parseMode = parseMode.value;
              await api.sendMessage(payload);
              toast('Message sent', 'success');
              close(true);
              await onDone();
            } catch (failure) {
              toastError(failure);
            }
          });
        }
      })
    ]
  });
}

async function removeChat(api, chat, onDone) {
  const confirmed = await confirmAction({
    title: 'Remove chat?',
    message: `${chat.title || chat.chatId} is removed from this panel. The bot itself stays in the Telegram chat.`,
    confirmLabel: 'Remove'
  });
  if (!confirmed) return;

  try {
    await api.deleteChat(chat.id);
    toast('Chat removed', 'success');
    await onDone();
  } catch (error) {
    toastError(error);
  }
}

function chatRow(api, chat, bots, botsById, onDone) {
  const bot = botsById.get(chat.botId);

  return el('tr', {},
    el('td', {},
      el('div', { class: 'cell-strong', text: chat.title || '(untitled)' }),
      el('div', { class: 'cell-sub mono', text: String(chat.chatId) })
    ),
    el('td', {}, chat.routeName
      ? el('span', { class: 'badge badge--ok badge--plain mono', text: chat.routeName })
      : el('span', { class: 'dim', text: '—' })),
    el('td', {}, badge(chat.chatType, chat.chatType === 'private' ? 'info' : 'mute')),
    el('td', { class: 'mid nowrap', text: bot ? bot.name : `bot #${chat.botId}` }),
    el('td', { class: 'dim nowrap', text: formatDate(chat.createdAt) }),
    el('td', { class: 'right' },
      el('div', { class: 'row-actions' },
        el('button', { class: 'btn btn--ghost btn--sm', type: 'button',
          text: chat.routeName ? 'Route' : 'Name route',
          onclick: () => openRouteDialog(api, chat, onDone) }),
        el('button', { class: 'btn btn--ghost btn--sm', type: 'button', text: 'Send',
          onclick: () => openSendDialog(api, chat, bots, onDone) }),
        el('button', { class: 'btn btn--ghost btn--sm btn--danger', type: 'button', text: 'Remove',
          onclick: () => removeChat(api, chat, onDone) })
      )
    )
  );
}

export async function renderChats({ api, bots, refresh }) {
  if (!bots.length) {
    return emptyState('No bots yet', 'Chats are tracked per bot — connect one first.');
  }

  const payload = await api.chats();
  const chats = payload.chats || [];
  const botsById = new Map(bots.map((bot) => [bot.id, bot]));
  const defaultBot = bots.find((bot) => bot.isDefault) || bots[0];

  const toolbar = el('div', { class: 'toolbar' },
    el('span', { class: 'eyebrow', text: `${chats.length} chat${chats.length === 1 ? '' : 's'}` }),
    el('span', { class: 'toolbar__spacer' }),
    el('button', { class: 'btn btn--primary btn--sm', type: 'button', text: '+ Register chat',
      onclick: () => openCreateDialog(api, bots, defaultBot.id, refresh) })
  );

  if (!chats.length) {
    return el('div', {}, toolbar,
      emptyState('No chats registered', 'Chats appear automatically when someone messages the bot, or register one by ID to push to it.'));
  }

  return el('div', {}, toolbar,
    el('div', { class: 'table-wrap' },
      el('table', { class: 'table' },
        el('thead', {}, el('tr', {},
          el('th', { text: 'Chat' }),
          el('th', { text: 'Route' }),
          el('th', { text: 'Type' }),
          el('th', { text: 'Bot' }),
          el('th', { text: 'Registered' }),
          el('th', { class: 'right', text: '' })
        )),
        el('tbody', {}, chats.map((chat) => chatRow(api, chat, bots, botsById, refresh)))
      )
    )
  );
}
