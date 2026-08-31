import { adminApi, getState } from '../store.js';
import {
  el, openModal, statusBadge, toastError, formatDate, relativeTime,
  formatNumber, listToText, emptyState, skeletonRows
} from '../ui.js';

const PAGE_SIZE = 50;

function detailRow(label, value) {
  if (value === null || value === undefined || value === '' ||
      (Array.isArray(value) && value.length === 0)) return [];
  return [el('dt', { text: label }), el('dd', { class: 'mono', text: listToText(value) })];
}

function openDetail(log) {
  return openModal({
    title: log.subject || '(no subject)',
    wide: true,
    render: () => el('div', { class: 'form-grid' },
      el('dl', { class: 'kv' },
        detailRow('Status', log.status),
        detailRow('Sent at', formatDate(log.createdAt)),
        detailRow('Organization', log.organizationName),
        detailRow('From', log.fromAddress),
        detailRow('To', log.toAddress),
        detailRow('Cc', log.cc),
        detailRow('Bcc', log.bcc),
        detailRow('Reply-to', log.replyTo),
        detailRow('Priority', log.priority)
      ),
      log.error ? el('div', {},
        el('p', { class: 'field__label', style: { marginBottom: 'var(--space-2)' }, text: 'Delivery error' }),
        el('pre', { class: 'log-error', text: log.error })
      ) : null
    ),
    footer: ({ close }) => el('button', { class: 'btn', type: 'button', text: 'Close', onclick: () => close(true) })
  });
}

function logRow(log) {
  return el('tr', { style: { cursor: 'pointer' }, onclick: () => openDetail(log) },
    el('td', { class: 'nowrap' },
      el('div', { class: 'mono', text: relativeTime(log.createdAt) }),
      el('div', { class: 'cell-sub', text: formatDate(log.createdAt) })
    ),
    el('td', {},
      el('div', { class: 'cell-strong', text: log.subject || '(no subject)' }),
      el('div', { class: 'cell-sub mono', text: listToText(log.toAddress) })
    ),
    el('td', { class: 'mid nowrap', text: log.organizationName || '—' }),
    el('td', { class: 'mono dim nowrap', text: log.fromAddress || '—' }),
    el('td', {}, statusBadge(log.status))
  );
}

export async function render() {
  const { organizations, clients } = getState();

  const orgFilter = el('select', { class: 'select' },
    el('option', { value: '', text: 'All organizations' }),
    organizations.map((organization) => el('option', { value: organization.id, text: organization.name }))
  );

  const clientFilter = el('select', { class: 'select' }, el('option', { value: '', text: 'All clients' }));

  const statusFilter = el('select', { class: 'select' },
    el('option', { value: '', text: 'Any status' }),
    el('option', { value: 'sent', text: 'Delivered' }),
    el('option', { value: 'failed', text: 'Failed' })
  );

  const search = el('input', { class: 'input', type: 'search', placeholder: 'Subject or recipient…' });

  const tbody = el('tbody');
  const results = el('div');
  const summary = el('span', { class: 'eyebrow' });
  const prev = el('button', { class: 'btn btn--sm', type: 'button', text: '← Newer' });
  const next = el('button', { class: 'btn btn--sm', type: 'button', text: 'Older →' });

  let offset = 0;
  let debounce;

  const syncClientOptions = () => {
    const orgId = orgFilter.value;
    const scoped = orgId ? clients.filter((entry) => String(entry.organizationId) === orgId) : clients;
    clientFilter.replaceChildren(
      el('option', { value: '', text: 'All clients' }),
      ...scoped.map((entry) => el('option', { value: entry.id, text: entry.fromAddress }))
    );
  };

  const load = async () => {
    results.replaceChildren(skeletonRows(5));
    try {
      const payload = await adminApi().logs({
        organization_id: orgFilter.value,
        client_id: clientFilter.value,
        status: statusFilter.value,
        q: search.value.trim(),
        limit: PAGE_SIZE,
        offset
      });

      const logs = payload.logs || [];
      const total = Number(payload.total) || 0;
      const from = total === 0 ? 0 : offset + 1;
      const to = offset + logs.length;
      summary.textContent = total ? `${formatNumber(from)}–${formatNumber(to)} of ${formatNumber(total)}` : 'no results';

      prev.disabled = offset === 0;
      next.disabled = offset + logs.length >= total;

      tbody.replaceChildren(...logs.map(logRow));
      results.replaceChildren(
        logs.length
          ? el('div', { class: 'table-wrap' },
              el('table', { class: 'table' },
                el('thead', {}, el('tr', {},
                  el('th', { text: 'When' }),
                  el('th', { text: 'Subject / recipient' }),
                  el('th', { text: 'Organization' }),
                  el('th', { text: 'From' }),
                  el('th', { text: 'Status' })
                )),
                tbody
              )
            )
          : emptyState('No log entries', 'Nothing matches these filters.')
      );
    } catch (error) {
      results.replaceChildren(emptyState('Could not load logs', error.message));
      toastError(error);
    }
  };

  const reset = () => { offset = 0; load(); };

  orgFilter.addEventListener('change', () => { syncClientOptions(); reset(); });
  clientFilter.addEventListener('change', reset);
  statusFilter.addEventListener('change', reset);
  search.addEventListener('input', () => {
    clearTimeout(debounce);
    debounce = setTimeout(reset, 300);
  });
  prev.addEventListener('click', () => { offset = Math.max(0, offset - PAGE_SIZE); load(); });
  next.addEventListener('click', () => { offset += PAGE_SIZE; load(); });

  syncClientOptions();
  await load();

  return el('section', { class: 'view' },
    el('header', { class: 'view__head' },
      el('div', {},
        el('span', { class: 'eyebrow', text: 'Observability' }),
        el('h1', { class: 'view__title', text: 'Mail logs' }),
        el('p', { class: 'view__sub', text: 'Every delivery attempt across every client. Click a row for the full envelope and error.' })
      )
    ),
    el('div', { class: 'toolbar' },
      orgFilter, clientFilter, statusFilter, search,
      el('span', { class: 'toolbar__spacer' }),
      summary, prev, next
    ),
    results
  );
}
