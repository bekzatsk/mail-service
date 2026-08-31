import {
  el, field, openModal, confirmAction, toast, toastError,
  badge, relativeTime, emptyState, withBusy
} from '../../ui.js';

function botStatus(bot) {
  if (!bot.isEnabled) return badge('disabled', 'mute');
  if (bot.lastError) return badge('error', 'bad');
  if (bot.lastSeen) return badge('listening', 'ok');
  return badge('starting', 'warn');
}

async function openCreateDialog(api, onDone) {
  const name = el('input', { class: 'input', type: 'text', placeholder: 'support-bot' });
  const token = el('input', { class: 'input input--mono', type: 'password', autocomplete: 'off',
    placeholder: '123456789:AA…' });
  const isDefault = el('input', { type: 'checkbox' });
  const error = el('p', { class: 'field__error' });
  const probe = el('div');

  await openModal({
    title: 'Connect a bot',
    render: () => el('div', { class: 'form-grid' },
      field('Name', name, 'Internal label — must be unique for this client.'),
      field('Bot token', token, 'Issued by @BotFather. Stored AES-256-CBC encrypted.'),
      el('label', { class: 'check' }, isDefault,
        el('span', { text: 'Use as the default bot when a request does not name one' })),
      probe,
      error
    ),
    footer: ({ close }) => [
      el('button', { class: 'btn', type: 'button', text: 'Cancel', onclick: () => close(false) }),
      el('button', {
        class: 'btn', type: 'button', text: 'Verify token',
        onclick: (event) => {
          if (!token.value.trim()) { error.textContent = 'Token is required.'; return; }
          error.textContent = '';
          withBusy(event.currentTarget, async () => {
            try {
              const result = await api.testBotToken(token.value.trim());
              probe.replaceChildren(el('p', {
                class: `callout ${result.success ? 'callout--ok' : 'callout--danger'}`,
                text: result.success ? `Token belongs to @${result.username} (id ${result.botId}).` : `Rejected: ${result.message}`
              }));
              if (result.success && !name.value.trim()) name.value = result.username;
            } catch (failure) {
              toastError(failure);
            }
          });
        }
      }),
      el('button', {
        class: 'btn btn--primary', type: 'button', text: 'Connect',
        onclick: (event) => {
          if (!name.value.trim()) { error.textContent = 'Name is required.'; return; }
          if (!token.value.trim()) { error.textContent = 'Token is required.'; return; }
          error.textContent = '';
          withBusy(event.currentTarget, async () => {
            try {
              await api.createBot({
                name: name.value.trim(),
                botToken: token.value.trim(),
                isDefault: isDefault.checked
              });
              toast('Bot connected — listener started', 'success');
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

async function openEditDialog(api, bot, onDone) {
  const name = el('input', { class: 'input', type: 'text', value: bot.name });
  const token = el('input', { class: 'input input--mono', type: 'password', autocomplete: 'off',
    placeholder: 'Leave blank to keep the current token' });
  const error = el('p', { class: 'field__error' });

  await openModal({
    title: `Edit ${bot.name}`,
    render: () => el('div', { class: 'form-grid' },
      field('Name', name),
      field('Replace bot token', token, 'Only fill this in when rotating the token with @BotFather.'),
      error
    ),
    footer: ({ close }) => [
      el('button', { class: 'btn', type: 'button', text: 'Cancel', onclick: () => close(false) }),
      el('button', {
        class: 'btn btn--primary', type: 'button', text: 'Save changes',
        onclick: (event) => {
          const payload = {};
          if (name.value.trim() && name.value.trim() !== bot.name) payload.name = name.value.trim();
          if (token.value.trim()) payload.botToken = token.value.trim();
          if (!Object.keys(payload).length) { error.textContent = 'Nothing to change.'; return; }
          error.textContent = '';
          withBusy(event.currentTarget, async () => {
            try {
              await api.updateBot(bot.id, payload);
              toast('Bot updated', 'success');
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

async function toggleEnabled(api, bot, onDone) {
  try {
    await api.updateBot(bot.id, { isEnabled: !bot.isEnabled });
    toast(bot.isEnabled ? 'Listener stopped' : 'Listener started', 'success');
    await onDone();
  } catch (error) {
    toastError(error);
  }
}

async function makeDefault(api, bot, onDone) {
  try {
    await api.updateBot(bot.id, { isDefault: true });
    toast(`${bot.name} is now the default bot`, 'success');
    await onDone();
  } catch (error) {
    toastError(error);
  }
}

async function removeBot(api, bot, onDone) {
  const confirmed = await confirmAction({
    title: `Disconnect ${bot.name}?`,
    message: 'The listener stops and every chat, command and message history for this bot is deleted. This cannot be undone.',
    confirmLabel: 'Disconnect'
  });
  if (!confirmed) return;

  try {
    await api.deleteBot(bot.id);
    toast('Bot disconnected', 'success');
    await onDone();
  } catch (error) {
    toastError(error);
  }
}

function botRow(api, bot, onDone) {
  return el('tr', {},
    el('td', {},
      el('div', { class: 'cell-strong', text: bot.name }),
      el('div', { class: 'cell-sub mono', text: bot.botUsername ? `@${bot.botUsername}` : '—' })
    ),
    el('td', {}, el('div', { class: 'badge-row' }, botStatus(bot), bot.isDefault ? badge('default', 'info') : null)),
    el('td', { class: 'dim nowrap', text: bot.lastSeen ? relativeTime(bot.lastSeen) : 'never' }),
    el('td', {}, bot.lastError
      ? el('span', { class: 'mono', style: { color: 'var(--c-danger)', fontSize: 'var(--text-xs)' }, text: bot.lastError })
      : el('span', { class: 'dim', text: '—' })),
    el('td', { class: 'right' },
      el('div', { class: 'row-actions' },
        el('button', { class: 'btn btn--ghost btn--sm', type: 'button',
          text: bot.isEnabled ? 'Stop' : 'Start',
          onclick: () => toggleEnabled(api, bot, onDone) }),
        bot.isDefault ? null : el('button', { class: 'btn btn--ghost btn--sm', type: 'button', text: 'Make default',
          onclick: () => makeDefault(api, bot, onDone) }),
        el('button', { class: 'btn btn--ghost btn--sm', type: 'button', text: 'Sync menu',
          title: 'Push enabled commands to Telegram via setMyCommands',
          onclick: (event) => withBusy(event.currentTarget, async () => {
            try {
              const result = await api.syncCommands(bot.id);
              toast(result.success ? 'Command menu synced' : 'Telegram rejected the sync', result.success ? 'success' : 'error');
            } catch (failure) {
              toastError(failure);
            }
          }) }),
        el('button', { class: 'btn btn--ghost btn--sm', type: 'button', text: 'Edit',
          onclick: () => openEditDialog(api, bot, onDone) }),
        el('button', { class: 'btn btn--ghost btn--sm btn--danger', type: 'button', text: 'Delete',
          onclick: () => removeBot(api, bot, onDone) })
      )
    )
  );
}

export async function renderBots({ api, bots, reloadBots, refresh }) {
  const onDone = async () => { await reloadBots(); await refresh(); };

  if (!bots.length) {
    return el('div', {},
      emptyState('No bots connected', 'Create a bot with @BotFather, then paste its token here to start a listener.',
        el('button', { class: 'btn btn--primary', type: 'button', text: 'Connect a bot',
          onclick: () => openCreateDialog(api, onDone) }))
    );
  }

  return el('div', {},
    el('div', { class: 'toolbar' },
      el('span', { class: 'eyebrow', text: `${bots.length} bot${bots.length === 1 ? '' : 's'}` }),
      el('span', { class: 'toolbar__spacer' }),
      el('button', { class: 'btn btn--primary btn--sm', type: 'button', text: '+ Connect a bot',
        onclick: () => openCreateDialog(api, onDone) })
    ),
    el('div', { class: 'table-wrap' },
      el('table', { class: 'table' },
        el('thead', {}, el('tr', {},
          el('th', { text: 'Bot' }),
          el('th', { text: 'State' }),
          el('th', { text: 'Last seen' }),
          el('th', { text: 'Last error' }),
          el('th', { class: 'right', text: '' })
        )),
        el('tbody', {}, bots.map((bot) => botRow(api, bot, onDone)))
      )
    )
  );
}
