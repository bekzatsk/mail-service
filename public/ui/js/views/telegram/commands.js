import {
  el, field, openModal, confirmAction, toast, toastError,
  badge, emptyState, withBusy
} from '../../ui.js';

const COMMAND_PATTERN = /^[a-z0-9_]{1,32}$/;

function botSelect(bots, selectedId) {
  return el('select', { class: 'select' },
    bots.map((bot) => el('option', {
      value: bot.id,
      selected: String(bot.id) === String(selectedId),
      text: bot.botUsername ? `${bot.name} · @${bot.botUsername}` : bot.name
    }))
  );
}

async function openCreateDialog(api, bots, defaultBotId, onDone) {
  const bot = botSelect(bots, defaultBotId);
  const command = el('input', { class: 'input input--mono', type: 'text', placeholder: 'status' });
  const description = el('input', { class: 'input', type: 'text', placeholder: 'Show current system status' });
  const handlerUrl = el('input', { class: 'input input--mono', type: 'url', placeholder: 'https://app.example.com/telegram/status' });
  const handlerSecret = el('input', { class: 'input input--mono', type: 'password', autocomplete: 'off' });
  const error = el('p', { class: 'field__error' });

  await openModal({
    title: 'New command',
    wide: true,
    render: () => el('div', { class: 'form-grid' },
      el('div', { class: 'form-grid form-grid--2' }, field('Bot', bot), field('Command', command, 'Lowercase letters, digits and underscores. No leading slash.')),
      field('Description', description, 'Shown in the Telegram command menu.'),
      field('Handler URL', handlerUrl, 'The listener POSTs the update here and replies with the JSON {text, parseMode} it gets back.'),
      field('Handler secret', handlerSecret, 'Sent as the X-Handler-Secret header so your endpoint can verify the caller.'),
      error
    ),
    footer: ({ close }) => [
      el('button', { class: 'btn', type: 'button', text: 'Cancel', onclick: () => close(false) }),
      el('button', {
        class: 'btn btn--primary', type: 'button', text: 'Create command',
        onclick: (event) => {
          const name = command.value.trim().toLowerCase().replace(/^\//, '');
          if (!COMMAND_PATTERN.test(name)) { error.textContent = 'Use 1–32 lowercase letters, digits or underscores.'; return; }
          if (!description.value.trim()) { error.textContent = 'Description is required.'; return; }
          error.textContent = '';

          withBusy(event.currentTarget, async () => {
            try {
              await api.createCommand({
                botId: Number(bot.value),
                command: name,
                description: description.value.trim(),
                handlerUrl: handlerUrl.value.trim() || null,
                handlerSecret: handlerSecret.value.trim() || null
              });
              toast(`/${name} created and pushed to Telegram`, 'success');
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

async function openEditDialog(api, record, onDone) {
  const description = el('input', { class: 'input', type: 'text', value: record.description });
  const handlerUrl = el('input', { class: 'input input--mono', type: 'url', value: record.handlerUrl || '' });
  const handlerSecret = el('input', { class: 'input input--mono', type: 'password', autocomplete: 'off',
    placeholder: record.hasHandlerSecret ? 'Leave blank to keep the stored secret' : '' });
  const error = el('p', { class: 'field__error' });

  await openModal({
    title: `Edit /${record.command}`,
    wide: true,
    render: () => el('div', { class: 'form-grid' },
      field('Description', description),
      field('Handler URL', handlerUrl),
      field('Handler secret', handlerSecret),
      error
    ),
    footer: ({ close }) => [
      el('button', { class: 'btn', type: 'button', text: 'Cancel', onclick: () => close(false) }),
      el('button', {
        class: 'btn btn--primary', type: 'button', text: 'Save changes',
        onclick: (event) => {
          if (!description.value.trim()) { error.textContent = 'Description is required.'; return; }
          error.textContent = '';

          const payload = { description: description.value.trim(), handlerUrl: handlerUrl.value.trim() || null };
          if (handlerSecret.value.trim()) payload.handlerSecret = handlerSecret.value.trim();

          withBusy(event.currentTarget, async () => {
            try {
              await api.updateCommand(record.id, payload);
              toast('Command updated', 'success');
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

async function toggleCommand(api, record, onDone) {
  try {
    await api.updateCommand(record.id, { isEnabled: !record.isEnabled });
    toast(record.isEnabled ? `/${record.command} disabled` : `/${record.command} enabled`, 'success');
    await onDone();
  } catch (error) {
    toastError(error);
  }
}

async function removeCommand(api, record, onDone) {
  const confirmed = await confirmAction({
    title: `Delete /${record.command}?`,
    message: 'The command is removed from the Telegram menu and stops being dispatched.',
    confirmLabel: 'Delete'
  });
  if (!confirmed) return;

  try {
    await api.deleteCommand(record.id);
    toast('Command deleted', 'success');
    await onDone();
  } catch (error) {
    toastError(error);
  }
}

function commandRow(api, record, botsById, onDone) {
  const bot = botsById.get(record.botId);

  return el('tr', {},
    el('td', {},
      el('div', { class: 'cell-strong mono', text: `/${record.command}` }),
      el('div', { class: 'cell-sub', text: record.description })
    ),
    el('td', { class: 'mid nowrap', text: bot ? bot.name : `bot #${record.botId}` }),
    el('td', {}, record.handlerUrl
      ? el('span', { class: 'mono', style: { fontSize: 'var(--text-xs)' }, text: record.handlerUrl })
      : el('span', { class: 'dim', text: 'no handler — command is acknowledged only' })),
    el('td', {}, record.hasHandlerSecret ? badge('secret set', 'ok') : badge('no secret', 'warn')),
    el('td', {}, record.isEnabled ? badge('enabled', 'ok') : badge('disabled', 'mute')),
    el('td', { class: 'right' },
      el('div', { class: 'row-actions' },
        el('button', { class: 'btn btn--ghost btn--sm', type: 'button',
          text: record.isEnabled ? 'Disable' : 'Enable',
          onclick: () => toggleCommand(api, record, onDone) }),
        el('button', { class: 'btn btn--ghost btn--sm', type: 'button', text: 'Edit',
          onclick: () => openEditDialog(api, record, onDone) }),
        el('button', { class: 'btn btn--ghost btn--sm btn--danger', type: 'button', text: 'Delete',
          onclick: () => removeCommand(api, record, onDone) })
      )
    )
  );
}

export async function renderCommands({ api, bots, refresh }) {
  if (!bots.length) {
    return emptyState('No bots yet', 'Commands hang off a bot — connect one first.');
  }

  const payload = await api.commands();
  const commands = payload.commands || [];
  const botsById = new Map(bots.map((bot) => [bot.id, bot]));
  const defaultBot = bots.find((bot) => bot.isDefault) || bots[0];

  const toolbar = el('div', { class: 'toolbar' },
    el('span', { class: 'eyebrow', text: `${commands.length} command${commands.length === 1 ? '' : 's'}` }),
    el('span', { class: 'toolbar__spacer' }),
    el('button', { class: 'btn btn--primary btn--sm', type: 'button', text: '+ New command',
      onclick: () => openCreateDialog(api, bots, defaultBot.id, refresh) })
  );

  if (!commands.length) {
    return el('div', {}, toolbar,
      emptyState('No commands', 'Slash commands are matched by the listener and forwarded to your handler URL.'));
  }

  return el('div', {}, toolbar,
    el('div', { class: 'table-wrap' },
      el('table', { class: 'table' },
        el('thead', {}, el('tr', {},
          el('th', { text: 'Command' }),
          el('th', { text: 'Bot' }),
          el('th', { text: 'Handler' }),
          el('th', { text: 'Auth' }),
          el('th', { text: 'State' }),
          el('th', { class: 'right', text: '' })
        )),
        el('tbody', {}, commands.map((record) => commandRow(api, record, botsById, refresh)))
      )
    )
  );
}
