import { adminApi, getState } from '../store.js';
import { el, formatNumber, relativeTime, statusBadge, listToText, emptyState } from '../ui.js';
import { navigate } from '../router.js';

function statTile(label, value, tone) {
  return el('div', { class: 'stat' },
    el('span', { class: `stat__value${tone ? ` stat__value--${tone}` : ''}`, text: formatNumber(value) }),
    el('span', { class: 'stat__label', text: label })
  );
}

function deliveryHealth(mail) {
  const total = Number(mail.sent) + Number(mail.failed);
  const sentPercent = total ? (Number(mail.sent) / total) * 100 : 0;
  const failedPercent = total ? 100 - sentPercent : 0;

  return el('div', { class: 'card' },
    el('div', { class: 'card__head' },
      el('h3', { class: 'card__title', text: 'Delivery health' }),
      el('span', { class: 'eyebrow', style: { marginLeft: 'auto' },
        text: total ? `${sentPercent.toFixed(1)}% delivered` : 'no data' })
    ),
    el('div', { class: 'card__body' },
      el('div', { class: 'bar' },
        el('div', { class: 'bar__seg bar__seg--ok', style: { width: `${sentPercent}%` } }),
        el('div', { class: 'bar__seg bar__seg--bad', style: { width: `${failedPercent}%` } })
      ),
      el('div', { class: 'bar-legend' },
        el('span', {}, el('b', { class: 'mono', style: { color: 'var(--c-accent)' }, text: formatNumber(mail.sent) }), ' sent'),
        el('span', {}, el('b', { class: 'mono', style: { color: 'var(--c-danger)' }, text: formatNumber(mail.failed) }), ' failed'),
        el('span', {}, el('b', { class: 'mono', text: formatNumber(mail.last24h) }), ' in last 24h')
      )
    )
  );
}

function recentLogs(logs) {
  if (!logs.length) {
    return el('div', { class: 'card' },
      el('div', { class: 'card__head' }, el('h3', { class: 'card__title', text: 'Recent mail' })),
      el('div', { class: 'card__body' }, emptyState('Nothing sent yet', 'Mail sent through any client key shows up here.'))
    );
  }

  return el('div', { class: 'card' },
    el('div', { class: 'card__head' },
      el('h3', { class: 'card__title', text: 'Recent mail' }),
      el('button', { class: 'btn btn--ghost btn--sm', type: 'button', text: 'All logs →',
        style: { marginLeft: 'auto' }, onclick: () => navigate('logs') })
    ),
    el('div', { class: 'table-wrap', style: { border: 0, borderRadius: 0 } },
      el('table', { class: 'table' },
        el('thead', {}, el('tr', {},
          el('th', { text: 'Recipient' }),
          el('th', { text: 'Subject' }),
          el('th', { text: 'Status' }),
          el('th', { class: 'right', text: 'When' })
        )),
        el('tbody', {}, logs.map((log) => el('tr', {},
          el('td', { class: 'mono truncate', text: listToText(log.toAddress) }),
          el('td', {},
            el('div', { class: 'cell-strong', text: log.subject || '(no subject)' }),
            el('div', { class: 'cell-sub', text: log.organizationName || '—' })
          ),
          el('td', {}, statusBadge(log.status)),
          el('td', { class: 'right dim nowrap', text: relativeTime(log.createdAt) })
        )))
      )
    )
  );
}

export async function render() {
  const { organizations, clients } = getState();
  const [stats, logsPayload] = await Promise.all([
    adminApi().stats(),
    adminApi().logs({ limit: 8 })
  ]);

  const enabledBots = Number(stats.telegram.enabled_bots);
  const totalBots = Number(stats.telegram.bots);

  return el('section', { class: 'view' },
    el('header', { class: 'hero' },
      el('span', { class: 'eyebrow', text: 'Control panel' }),
      el('h1', { class: 'hero__title' }, 'Mail and Telegram ', el('em', { text: 'delivery' }), ' for ',
        formatNumber(organizations.length), organizations.length === 1 ? ' organization' : ' organizations'),
      el('div', { class: 'hero__meta' },
        el('span', {}, formatNumber(clients.length), ' client keys issued'),
        el('span', {}, formatNumber(stats.mail.total), ' messages logged'),
        el('span', {}, `${formatNumber(enabledBots)} of ${formatNumber(totalBots)} bots running`)
      )
    ),

    el('div', { class: 'stats' },
      statTile('Organizations', stats.organizations),
      statTile('Client keys', stats.clients),
      statTile('Delivered', stats.mail.sent, 'ok'),
      statTile('Failed', stats.mail.failed, Number(stats.mail.failed) > 0 ? 'bad' : undefined),
      statTile('Last 24h', stats.mail.last24h),
      statTile('Telegram msgs', stats.telegram.messages)
    ),

    el('div', { class: 'split section' },
      recentLogs(logsPayload.logs || []),
      el('div', { style: { display: 'grid', gap: 'var(--space-5)' } },
        deliveryHealth(stats.mail),
        el('div', { class: 'card' },
          el('div', { class: 'card__head' }, el('h3', { class: 'card__title', text: 'Quick actions' })),
          el('div', { class: 'card__body', style: { display: 'grid', gap: 'var(--space-2)' } },
            el('button', { class: 'btn btn--block', type: 'button', text: 'New organization',
              onclick: () => navigate('organizations?new=1') }),
            el('button', { class: 'btn btn--block', type: 'button', text: 'Issue client key',
              onclick: () => navigate('clients?new=1') }),
            el('button', { class: 'btn btn--block', type: 'button', text: 'Send a test email',
              onclick: () => navigate('send') })
          )
        )
      )
    )
  );
}
