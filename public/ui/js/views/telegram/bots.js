import {
  el, field, openModal, confirmAction, toast, toastError,
  badge, relativeTime, formatDate, emptyState, withBusy
} from '../../ui.js';
import { getState } from '../../store.js';

function botStatus(bot) {
  if (!bot.isEnabled) return badge('disabled', 'mute');
  if (bot.lastError) return badge('error', 'bad');
  if (bot.lastSeen) return badge('listening', 'ok');
  return badge('starting', 'warn');
}

// Webhook means Telegram pushes updates to us; polling means a thread inside
// the app process pulls them. Under Passenger the thread dies with an idle
// process and duplicates across workers, so this is the more load-bearing
// column than it looks.
function transportBadge(bot) {
  return bot.deliveryMode === 'webhook'
    ? badge('webhook', 'ok')
    : badge('polling', 'warn');
}

async function switchToWebhook(api, bot, onDone) {
  const baseUrl = el('input', {
    class: 'input input--mono', type: 'url',
    placeholder: window.location.origin, value: window.location.origin
  });
  const dropPending = el('input', { type: 'checkbox' });
  const error = el('p', { class: 'field__error' });

  await openModal({
    title: `Switch ${bot.name} to webhook`,
    wide: true,
    render: () => el('div', { class: 'form-grid' },
      el('p', { class: 'mid', text: 'Telegram will POST updates to this service instead of the app polling for them. '
        + 'The listener thread for this bot stops, which is the point: under Passenger it dies with an idle process and duplicates across workers.' }),
      field('Public base URL', baseUrl, 'Must be https and reachable from Telegram. The webhook path is appended automatically.'),
      el('label', { class: 'check' }, dropPending,
        el('span', { text: 'Discard updates queued while polling was down' })),
      el('p', { class: 'callout', text: 'A fresh secret token is generated and handed to Telegram. It is the only thing authenticating inbound updates, so it is stored, never shown, and replaced on every switch.' }),
      error
    ),
    footer: ({ close }) => [
      el('button', { class: 'btn', type: 'button', text: 'Cancel', onclick: () => close(false) }),
      el('button', {
        class: 'btn btn--primary', type: 'button', text: 'Register webhook',
        onclick: (event) => {
          const base = baseUrl.value.trim();
          if (!base.startsWith('https://')) {
            error.textContent = 'Telegram only accepts an https URL.';
            return;
          }
          error.textContent = '';
          withBusy(event.currentTarget, async () => {
            try {
              const result = await api.enableWebhook(bot.id, {
                baseUrl: base,
                dropPendingUpdates: dropPending.checked
              });
              toast(`${bot.name} now receives updates at ${result.webhookUrl}`, 'success', 6000);
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

async function switchToPolling(api, bot, onDone) {
  const confirmed = await confirmAction({
    title: `Switch ${bot.name} back to polling?`,
    message: 'The webhook is removed at Telegram and a listener thread starts for this bot. '
      + 'On a host that suspends idle processes the bot will stop responding whenever the app goes cold.',
    confirmLabel: 'Switch to polling',
    tone: 'default'
  });
  if (!confirmed) return;

  try {
    await api.disableWebhook(bot.id);
    toast(`${bot.name} is back on long polling`, 'success');
    await onDone();
  } catch (error) {
    toastError(error);
  }
}

async function showWebhookInfo(api, bot) {
  let info;
  try {
    info = await api.webhookInfo(bot.id);
  } catch (error) {
    toastError(error);
    return;
  }

  const tg = info.telegram || {};
  const row = (label, value) => (value === null || value === undefined || value === ''
    ? []
    : [el('dt', { text: label }), el('dd', { class: 'mono', text: String(value) })]);

  await openModal({
    title: `Webhook — ${bot.name}`,
    wide: true,
    render: () => el('div', { class: 'form-grid' },
      el('dl', { class: 'kv' },
        row('Mode', info.deliveryMode),
        row('Registered', info.registered ? 'yes' : 'no'),
        row('URL', tg.url),
        row('Pending updates', tg.pendingUpdateCount),
        row('Max connections', tg.maxConnections),
        row('Telegram IP', tg.ipAddress),
        row('Last error at', tg.lastErrorDate ? formatDate(new Date(tg.lastErrorDate * 1000).toISOString()) : null)
      ),
      tg.lastErrorMessage
        ? el('div', {},
            el('p', { class: 'field__label', style: { marginBottom: 'var(--space-2)' }, text: 'Last delivery error' }),
            el('pre', { class: 'log-error', text: tg.lastErrorMessage })
          )
        : null
    ),
    footer: ({ close }) => el('button', { class: 'btn', type: 'button', text: 'Close', onclick: () => close(true) })
  });
}

// A grant lends the bot to another organization: its clients get the chats,
// routes, commands, history and sending. It never gets the token, the webhook
// or the delete button — those are one-per-bot and stay with the owner.
async function openAccessDialog(api, bot, onDone) {
  const rows = el('tbody');
  const picker = el('select', { class: 'input' });
  const error = el('p', { class: 'field__error' });
  let grants = bot.grants || [];

  const paint = () => {
    const organizations = getState().organizations || [];
    const taken = new Set(grants.map((grant) => grant.organizationId));

    rows.replaceChildren(...(grants.length
      ? grants.map((grant) => el('tr', {},
          el('td', {},
            el('div', { class: 'cell-strong', text: grant.organizationName || `#${grant.organizationId}` }),
            el('div', { class: 'cell-sub mono', text: grant.organizationSlug || '' })
          ),
          el('td', { class: 'dim nowrap', text: grant.createdAt ? formatDate(grant.createdAt) : '—' }),
          el('td', { class: 'right' },
            el('button', {
              class: 'btn btn--ghost btn--sm btn--danger', type: 'button', text: 'Revoke',
              onclick: (event) => withBusy(event.currentTarget, async () => {
                try {
                  await api.revokeBotGrant(bot.id, grant.id);
                  grants = grants.filter((entry) => entry.id !== grant.id);
                  toast(`${grant.organizationName} can no longer use ${bot.name}`, 'success');
                  paint();
                  await onDone();
                } catch (failure) {
                  toastError(failure);
                }
              })
            })
          )
        ))
      : [el('tr', {}, el('td', { colspan: '3', class: 'dim',
          text: 'Only this bot\u2019s own organization can use it.' }))]));

    const available = organizations.filter((org) =>
      !taken.has(org.id) && org.id !== bot.ownerOrganizationId);

    picker.replaceChildren(
      el('option', { value: '', text: available.length ? 'Select an organization…' : 'No other organization left' }),
      ...available.map((org) => el('option', { value: String(org.id), text: `${org.name} (${org.slug})` }))
    );
    picker.disabled = available.length === 0;
  };

  paint();

  await openModal({
    title: `Access — ${bot.name}`,
    wide: true,
    render: () => el('div', { class: 'form-grid' },
      el('p', { class: 'mid', text: 'Organizations listed here may register chats and routes on this bot, '
        + 'edit its commands, read its message history and send through it. They cannot see or rotate the token, '
        + 'change the transport, or delete the bot.' }),
      el('p', { class: 'callout', text: 'One bot is one Telegram identity. A grantee can also reach the routes '
        + 'the other organizations created on it — grant it to someone you would let post in every one of these chats.' }),
      el('div', { class: 'table-wrap' },
        el('table', { class: 'table' },
          el('thead', {}, el('tr', {},
            el('th', { text: 'Organization' }),
            el('th', { text: 'Granted' }),
            el('th', { class: 'right', text: '' })
          )),
          rows
        )
      ),
      field('Grant access to', picker),
      error
    ),
    footer: ({ close }) => [
      el('button', { class: 'btn', type: 'button', text: 'Close', onclick: () => close(true) }),
      el('button', {
        class: 'btn btn--primary', type: 'button', text: 'Grant access',
        onclick: (event) => {
          if (!picker.value) { error.textContent = 'Pick an organization first.'; return; }
          error.textContent = '';
          withBusy(event.currentTarget, async () => {
            try {
              const result = await api.grantBot(bot.id, { organizationId: Number(picker.value) });
              grants = [...grants, result.grant];
              toast(`${result.grant.organizationName} can now use ${bot.name}`, 'success');
              paint();
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
  const handlerUrl = el('input', { class: 'input input--mono', type: 'url',
    value: bot.messageHandlerUrl || '', placeholder: 'https://your-project.example/telegram/message' });
  const handlerSecret = el('input', { class: 'input input--mono', type: 'password', autocomplete: 'off',
    placeholder: bot.hasMessageHandlerSecret ? 'Leave blank to keep the stored secret' : '' });
  const error = el('p', { class: 'field__error' });

  await openModal({
    title: `Edit ${bot.name}`,
    wide: true,
    render: () => el('div', { class: 'form-grid' },
      field('Name', name),
      field('Replace bot token', token, 'Only fill this in when rotating the token with @BotFather.'),
      el('div', { class: 'section__head' }, el('span', { class: 'eyebrow', text: 'Inbound messages' })),
      el('p', { class: 'mid', text: 'Anything no command claims — ordinary text, and slash commands with no row — is POSTed here. '
        + 'Without a handler those messages only reach the log. Reply {"text": "..."} to answer in the chat, or with nothing to stay silent.' }),
      field('Message handler URL', handlerUrl, 'Leave empty to go back to log-only.'),
      field('Handler secret', handlerSecret, 'Sent as X-Handler-Secret so your endpoint can verify the caller.'),
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

          const url = handlerUrl.value.trim();
          if (url && !/^https?:\/\//.test(url)) {
            error.textContent = 'Message handler URL must start with http:// or https://.';
            return;
          }
          if (url !== (bot.messageHandlerUrl || '')) payload.messageHandlerUrl = url;
          if (handlerSecret.value.trim()) payload.messageHandlerSecret = handlerSecret.value.trim();

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
  // A borrowed bot shows the same rows and the same commands, but none of the
  // buttons that touch the bot itself — the service would answer 404 anyway.
  const owned = bot.isOwner !== false;
  const grantCount = (bot.grants || []).length;

  const syncMenu = el('button', { class: 'btn btn--ghost btn--sm', type: 'button', text: 'Sync menu',
    title: 'Push enabled commands to Telegram via setMyCommands',
    onclick: (event) => withBusy(event.currentTarget, async () => {
      try {
        const result = await api.syncCommands(bot.id);
        toast(result.success ? 'Command menu synced' : 'Telegram rejected the sync', result.success ? 'success' : 'error');
      } catch (failure) {
        toastError(failure);
      }
    }) });

  const ownerActions = owned ? [
    el('button', { class: 'btn btn--ghost btn--sm', type: 'button',
      text: bot.isEnabled ? 'Stop' : 'Start',
      onclick: () => toggleEnabled(api, bot, onDone) }),
    bot.isDefault ? null : el('button', { class: 'btn btn--ghost btn--sm', type: 'button', text: 'Make default',
      onclick: () => makeDefault(api, bot, onDone) }),
    syncMenu,
    el('button', { class: 'btn btn--ghost btn--sm', type: 'button',
      text: grantCount ? `Access · ${grantCount}` : 'Access',
      title: 'Which other organizations may use this bot',
      onclick: () => openAccessDialog(api, bot, onDone) }),
    bot.deliveryMode === 'webhook'
      ? el('button', { class: 'btn btn--ghost btn--sm', type: 'button', text: 'Webhook',
          title: 'What Telegram has registered', onclick: () => showWebhookInfo(api, bot) })
      : null,
    bot.deliveryMode === 'webhook'
      ? el('button', { class: 'btn btn--ghost btn--sm', type: 'button', text: 'Use polling',
          onclick: () => switchToPolling(api, bot, onDone) })
      : el('button', { class: 'btn btn--ghost btn--sm', type: 'button', text: 'Use webhook',
          title: 'Let Telegram push updates instead of polling for them',
          onclick: () => switchToWebhook(api, bot, onDone) }),
    el('button', { class: 'btn btn--ghost btn--sm', type: 'button', text: 'Edit',
      onclick: () => openEditDialog(api, bot, onDone) }),
    el('button', { class: 'btn btn--ghost btn--sm btn--danger', type: 'button', text: 'Delete',
      onclick: () => removeBot(api, bot, onDone) })
  ] : [syncMenu];

  return el('tr', {},
    el('td', {},
      el('div', { class: 'cell-strong', text: bot.name }),
      el('div', { class: 'cell-sub mono', text: bot.botUsername ? `@${bot.botUsername}` : '—' }),
      owned ? null : el('div', { class: 'cell-sub',
        text: `shared by ${bot.ownerOrganizationName || 'another organization'}` })
    ),
    el('td', {}, el('div', { class: 'badge-row' },
      botStatus(bot),
      bot.isDefault ? badge('default', 'info') : null,
      bot.messageHandlerUrl ? badge('msg handler', 'info') : null,
      owned
        ? (grantCount ? badge(`shared ×${grantCount}`, 'info') : null)
        : badge('borrowed', 'warn'))),
    el('td', {}, transportBadge(bot)),
    el('td', { class: 'dim nowrap', text: bot.lastSeen ? relativeTime(bot.lastSeen) : 'never' }),
    el('td', {}, bot.lastError
      ? el('span', { class: 'mono', style: { color: 'var(--c-danger)', fontSize: 'var(--text-xs)' }, text: bot.lastError })
      : el('span', { class: 'dim', text: '—' })),
    el('td', { class: 'right' }, el('div', { class: 'row-actions' }, ownerActions))
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
          el('th', { text: 'Transport' }),
          el('th', { text: 'Last seen' }),
          el('th', { text: 'Last error' }),
          el('th', { class: 'right', text: '' })
        )),
        el('tbody', {}, bots.map((bot) => botRow(api, bot, onDone)))
      )
    )
  );
}
