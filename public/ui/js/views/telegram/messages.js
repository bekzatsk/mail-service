import {
  el, statusBadge, toastError, formatDate, relativeTime, emptyState
} from '../../ui.js';

const PAGE_SIZE = 100;

function messageCard(message, botsById) {
  const bot = botsById.get(message.botId);
  const outbound = message.direction === 'outbound';

  return el('article', { class: `msg msg--${outbound ? 'outbound' : 'inbound'}` },
    el('div', { class: 'msg__meta' },
      el('span', { text: outbound ? '→ out' : '← in' }),
      el('span', { text: bot ? bot.name : `bot #${message.botId}` }),
      el('span', { text: `chat ${message.chatId}` }),
      message.username ? el('span', { text: `@${message.username}` }) : null,
      el('span', { title: formatDate(message.createdAt), text: relativeTime(message.createdAt) })
    ),
    el('div', { class: 'msg__text', text: message.text || '(no text)' }),
    message.status === 'sent' && outbound ? null : el('div', {}, statusBadge(message.status)),
    message.errorMessage ? el('pre', { class: 'log-error', text: message.errorMessage }) : null
  );
}

export async function renderMessages({ api, bots }) {
  const botsById = new Map(bots.map((bot) => [bot.id, bot]));

  const botFilter = el('select', { class: 'select' },
    el('option', { value: '', text: 'All bots' }),
    bots.map((bot) => el('option', { value: bot.id, text: bot.name }))
  );

  const directionFilter = el('select', { class: 'select' },
    el('option', { value: '', text: 'Both directions' }),
    el('option', { value: 'inbound', text: 'Inbound only' }),
    el('option', { value: 'outbound', text: 'Outbound only' })
  );

  const thread = el('div', { class: 'thread' });
  const summary = el('span', { class: 'eyebrow' });

  const load = async () => {
    try {
      const payload = await api.messages({
        botId: botFilter.value,
        direction: directionFilter.value,
        limit: PAGE_SIZE
      });
      const messages = (payload.messages || []).slice().reverse();
      summary.textContent = `${messages.length} message${messages.length === 1 ? '' : 's'}`;
      thread.replaceChildren(
        messages.length
          ? el('div', { class: 'thread' }, messages.map((message) => messageCard(message, botsById)))
          : emptyState('No messages', 'Inbound updates and outbound sends both land here.')
      );
    } catch (error) {
      thread.replaceChildren(emptyState('Could not load messages', error.message));
      toastError(error);
    }
  };

  botFilter.addEventListener('change', load);
  directionFilter.addEventListener('change', load);
  await load();

  return el('div', {},
    el('div', { class: 'toolbar' },
      botFilter, directionFilter,
      el('span', { class: 'toolbar__spacer' }),
      summary,
      el('button', { class: 'btn btn--sm', type: 'button', text: 'Refresh', onclick: load })
    ),
    thread
  );
}
