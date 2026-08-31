import { adminApi, getState, refresh, selectClient } from '../store.js';
import { navigate, currentRoute } from '../router.js';
import {
  el, field, openModal, confirmAction, toast, toastError, secretChip,
  formatNumber, emptyState, withBusy
} from '../ui.js';

const PORT_HINT = 'Port 465 uses implicit SSL; anything else negotiates STARTTLS.';

function smtpFields(values = {}) {
  const host = el('input', { class: 'input', type: 'text', value: values.smtpHost || '', placeholder: 'smtp.example.com' });
  const port = el('input', { class: 'input input--mono', type: 'number', min: '1', max: '65535',
    value: values.smtpPort || 587 });
  const user = el('input', { class: 'input', type: 'text', value: values.smtpUser || '', placeholder: 'no-reply@example.com' });
  const pass = el('input', { class: 'input', type: 'password', autocomplete: 'new-password',
    placeholder: values.id ? 'Leave blank to keep the stored password' : '' });
  const from = el('input', { class: 'input', type: 'email', value: values.fromAddress || '',
    placeholder: 'Acme <no-reply@example.com>' });

  return { host, port, user, pass, from };
}

function smtpFormBody(fields, extra = []) {
  return el('div', { class: 'form-grid' },
    ...extra,
    el('div', { class: 'form-grid form-grid--2' },
      field('SMTP host', fields.host),
      field('Port', fields.port, PORT_HINT)
    ),
    el('div', { class: 'form-grid form-grid--2' },
      field('SMTP user', fields.user),
      field('SMTP password', fields.pass)
    ),
    field('From address', fields.from, 'Default sender used when a send request omits "from".')
  );
}

function readSmtp(fields, { requirePassword }) {
  const payload = {
    smtp_host: fields.host.value.trim(),
    smtp_port: Number(fields.port.value),
    smtp_user: fields.user.value.trim(),
    smtp_pass: fields.pass.value,
    from_address: fields.from.value.trim()
  };

  if (!payload.smtp_host) return { error: 'SMTP host is required.' };
  if (!payload.smtp_port || payload.smtp_port < 1 || payload.smtp_port > 65535) return { error: 'Port must be between 1 and 65535.' };
  if (!payload.smtp_user) return { error: 'SMTP user is required.' };
  if (requirePassword && !payload.smtp_pass) return { error: 'SMTP password is required.' };
  if (!payload.from_address) return { error: 'From address is required.' };

  return { payload };
}

// ── Create ──────────────────────────────────────────────────────────

function showIssuedKey(apiKey) {
  return openModal({
    title: 'Client key issued',
    render: () => el('div', { class: 'form-grid' },
      el('p', { class: 'mid', text: 'Hand this key to the integrating application. It authenticates every /send and /telegram request.' }),
      el('div', {}, secretChip(apiKey, { revealed: true })),
      el('p', { class: 'callout', text: 'Anyone holding this key can send mail as this client and read the whole organization’s mail log. Store it in a secret manager, not in source control.' })
    ),
    footer: ({ close }) => el('button', { class: 'btn btn--primary', type: 'button', text: 'Done', onclick: () => close(true) })
  });
}

async function openCreateDialog(defaultOrganizationId, onDone) {
  const { organizations } = getState();

  if (!organizations.length) {
    toast('Create an organization first — a client key must belong to one.', 'error');
    navigate('organizations');
    return;
  }

  const orgSelect = el('select', { class: 'select' },
    organizations.map((organization) => el('option', {
      value: organization.id,
      selected: String(organization.id) === String(defaultOrganizationId),
      text: `${organization.name} · ${organization.slug}`
    }))
  );

  const fields = smtpFields();
  const testBeforeSave = el('input', { type: 'checkbox', checked: true });
  const error = el('p', { class: 'field__error' });
  const testResult = el('div');

  const body = el('div', { class: 'form-grid' },
    smtpFormBody(fields, [field('Organization', orgSelect)]),
    el('label', { class: 'check' }, testBeforeSave,
      el('span', { text: 'Verify the SMTP credentials before saving (rejects the client if the connection fails)' })),
    testResult,
    error
  );

  await openModal({
    title: 'Issue client key',
    wide: true,
    render: () => body,
    footer: ({ close }) => [
      el('button', { class: 'btn', type: 'button', text: 'Cancel', onclick: () => close(false) }),
      el('button', {
        class: 'btn', type: 'button', text: 'Test connection',
        onclick: (event) => {
          const { payload, error: message } = readSmtp(fields, { requirePassword: true });
          if (message) { error.textContent = message; return; }
          error.textContent = '';
          withBusy(event.currentTarget, async () => {
            try {
              const result = await adminApi().testSmtp(payload);
              testResult.replaceChildren(el('p', {
                class: `callout ${result.success ? 'callout--ok' : 'callout--danger'}`,
                text: result.success ? 'Connection and authentication succeeded.' : `Failed: ${result.message}`
              }));
            } catch (failure) {
              toastError(failure);
            }
          });
        }
      }),
      el('button', {
        class: 'btn btn--primary', type: 'button', text: 'Create client',
        onclick: (event) => {
          const { payload, error: message } = readSmtp(fields, { requirePassword: true });
          if (message) { error.textContent = message; return; }
          error.textContent = '';
          withBusy(event.currentTarget, async () => {
            try {
              const result = await adminApi().createClient({
                ...payload,
                organization_id: Number(orgSelect.value),
                test_before_save: testBeforeSave.checked
              });
              close(true);
              await onDone();
              await showIssuedKey(result.api_key);
            } catch (failure) {
              toastError(failure);
            }
          });
        }
      })
    ]
  });
}

// ── Edit / lifecycle ────────────────────────────────────────────────

async function openEditDialog(record, onDone) {
  const fields = smtpFields(record);
  const error = el('p', { class: 'field__error' });

  await openModal({
    title: `Edit ${record.fromAddress}`,
    wide: true,
    render: () => el('div', { class: 'form-grid' }, smtpFormBody(fields), error),
    footer: ({ close }) => [
      el('button', { class: 'btn', type: 'button', text: 'Cancel', onclick: () => close(false) }),
      el('button', {
        class: 'btn btn--primary', type: 'button', text: 'Save changes',
        onclick: (event) => {
          const { payload, error: message } = readSmtp(fields, { requirePassword: false });
          if (message) { error.textContent = message; return; }
          error.textContent = '';
          // Omit the password entirely when left blank so the stored one survives.
          if (!payload.smtp_pass) delete payload.smtp_pass;
          withBusy(event.currentTarget, async () => {
            try {
              await adminApi().updateClient(record.id, payload);
              toast('Client updated', 'success');
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

async function rotateKey(record, onDone) {
  const confirmed = await confirmAction({
    title: 'Rotate API key?',
    message: `The current key for ${record.fromAddress} stops working the moment the new one is issued. `
      + 'Any application still using the old key will start receiving 403 responses.',
    confirmLabel: 'Rotate key'
  });
  if (!confirmed) return;

  try {
    const result = await adminApi().rotateClientKey(record.id);
    await onDone();
    await showIssuedKey(result.api_key);
  } catch (error) {
    toastError(error);
  }
}

async function testStoredCredentials(record, button) {
  await withBusy(button, async () => {
    try {
      const result = await adminApi().testClient(record.id);
      toast(result.success ? `${record.smtpHost} accepted the stored credentials` : `SMTP test failed: ${result.message}`,
        result.success ? 'success' : 'error', result.success ? 3500 : 8000);
    } catch (error) {
      toastError(error);
    }
  });
}

async function removeClient(record, onDone) {
  const confirmed = await confirmAction({
    title: 'Delete client key?',
    message: `This removes the key, its ${formatNumber(record.logsCount)} mail log entries and `
      + `${formatNumber(record.botsCount)} Telegram bot(s). This cannot be undone.`,
    confirmLabel: 'Delete permanently'
  });
  if (!confirmed) return;

  try {
    await adminApi().deleteClient(record.id);
    toast('Client deleted', 'success');
    await onDone();
  } catch (error) {
    toastError(error);
  }
}

// ── Table ───────────────────────────────────────────────────────────

function clientRow(record, onDone) {
  return el('tr', {},
    el('td', {},
      el('div', { class: 'cell-strong', text: record.fromAddress }),
      el('div', { class: 'cell-sub', text: record.organizationName })
    ),
    el('td', { class: 'mono nowrap' },
      el('div', { text: `${record.smtpHost}:${record.smtpPort}` }),
      el('div', { class: 'cell-sub', text: record.smtpUser })
    ),
    el('td', {}, secretChip(record.apiKey)),
    el('td', { class: 'right mono dim', text: formatNumber(record.logsCount) }),
    el('td', { class: 'right' },
      el('div', { class: 'row-actions' },
        el('button', { class: 'btn btn--ghost btn--sm', type: 'button', text: 'Scope',
          title: 'Use this client for Telegram and test sends',
          onclick: () => { selectClient(record.id); toast(`Scoped to ${record.fromAddress}`, 'success', 2000); } }),
        el('button', { class: 'btn btn--ghost btn--sm', type: 'button', text: 'Test',
          onclick: (event) => testStoredCredentials(record, event.currentTarget) }),
        el('button', { class: 'btn btn--ghost btn--sm', type: 'button', text: 'Edit',
          onclick: () => openEditDialog(record, onDone) }),
        el('button', { class: 'btn btn--ghost btn--sm', type: 'button', text: 'Rotate',
          onclick: () => rotateKey(record, onDone) }),
        el('button', { class: 'btn btn--ghost btn--sm btn--danger', type: 'button', text: 'Delete',
          onclick: () => removeClient(record, onDone) })
      )
    )
  );
}

export async function render() {
  const reload = () => refresh();
  const { clients, organizations } = getState();
  const route = currentRoute();
  const initialOrg = route?.query?.organization_id || '';

  const orgFilter = el('select', { class: 'select' },
    el('option', { value: '', text: 'All organizations' }),
    organizations.map((organization) => el('option', {
      value: organization.id,
      selected: String(organization.id) === String(initialOrg),
      text: organization.name
    }))
  );
  const search = el('input', { class: 'input', type: 'search', placeholder: 'Filter by address or host…' });

  const tbody = el('tbody');
  const count = el('span', { class: 'eyebrow' });

  const paint = () => {
    const needle = search.value.trim().toLowerCase();
    const orgId = orgFilter.value;

    const visible = clients.filter((record) => {
      if (orgId && String(record.organizationId) !== orgId) return false;
      if (!needle) return true;
      return [record.fromAddress, record.smtpHost, record.smtpUser, record.organizationName]
        .some((value) => String(value).toLowerCase().includes(needle));
    });

    count.textContent = `${formatNumber(visible.length)} of ${formatNumber(clients.length)}`;
    tbody.replaceChildren(...visible.map((record) => clientRow(record, reload)));
    empty.replaceChildren(...(visible.length ? [] : [emptyState(
      clients.length ? 'No match' : 'No client keys yet',
      clients.length ? 'Adjust the filters above.' : 'A client bundles SMTP credentials with an API key an application can use.'
    )]));
  };

  const empty = el('div', { style: { marginTop: 'var(--space-4)' } });
  orgFilter.addEventListener('change', paint);
  search.addEventListener('input', paint);
  paint();

  if (route?.query?.new === '1') {
    navigate('clients', { replace: true });
    openCreateDialog(initialOrg, reload);
  }

  return el('section', { class: 'view' },
    el('header', { class: 'view__head' },
      el('div', {},
        el('span', { class: 'eyebrow', text: 'Credentials' }),
        el('h1', { class: 'view__title', text: 'Clients & keys' }),
        el('p', { class: 'view__sub', text: 'One row per API key. Each carries its own SMTP configuration; the password is stored encrypted.' })
      ),
      el('div', { class: 'view__actions' },
        el('button', { class: 'btn btn--primary', type: 'button', text: '+ Issue client key',
          onclick: () => openCreateDialog(orgFilter.value, reload) })
      )
    ),
    el('div', { class: 'toolbar' }, orgFilter, search, el('span', { class: 'toolbar__spacer' }), count),
    el('div', { class: 'table-wrap' },
      el('table', { class: 'table' },
        el('thead', {}, el('tr', {},
          el('th', { text: 'From / organization' }),
          el('th', { text: 'SMTP' }),
          el('th', { text: 'API key' }),
          el('th', { class: 'right', text: 'Logs' }),
          el('th', { class: 'right', text: '' })
        )),
        tbody
      )
    ),
    empty
  );
}
