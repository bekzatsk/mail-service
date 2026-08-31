import { clientApi, selectedClient } from '../store.js';
import { navigate } from '../router.js';
import { el, field, toast, toastError, emptyState, withBusy } from '../ui.js';

function splitAddresses(value) {
  return value.split(/[,;\n]/).map((entry) => entry.trim()).filter(Boolean);
}

function noClientScoped() {
  return el('section', { class: 'view' },
    el('header', { class: 'view__head' },
      el('div', {},
        el('span', { class: 'eyebrow', text: 'Compose' }),
        el('h1', { class: 'view__title', text: 'Send a test email' })
      )
    ),
    emptyState(
      'No client selected',
      'Sending goes through a client API key. Pick one in the header, or issue a key first.',
      el('button', { class: 'btn btn--primary', type: 'button', text: 'Go to clients',
        onclick: () => navigate('clients') })
    )
  );
}

export async function render() {
  const current = selectedClient();
  const api = clientApi();
  if (!current || !api) return noClientScoped();

  const to = el('input', { class: 'input', type: 'text', placeholder: 'someone@example.com, other@example.com' });
  const cc = el('input', { class: 'input', type: 'text', placeholder: 'optional' });
  const bcc = el('input', { class: 'input', type: 'text', placeholder: 'optional' });
  const replyTo = el('input', { class: 'input', type: 'text', placeholder: 'optional' });
  const from = el('input', { class: 'input', type: 'text', placeholder: current.fromAddress });
  const subject = el('input', { class: 'input', type: 'text', placeholder: 'Deployment check' });
  const body = el('textarea', { class: 'textarea', placeholder: 'Plain text or HTML — HTML is auto-detected unless you force a format below.' });

  const format = el('select', { class: 'select' },
    el('option', { value: 'auto', text: 'Auto-detect' }),
    el('option', { value: 'html', text: 'Force HTML' }),
    el('option', { value: 'text', text: 'Force plain text' })
  );

  const priority = el('select', { class: 'select' },
    el('option', { value: '', text: 'Normal priority' }),
    el('option', { value: 'high', text: 'High' }),
    el('option', { value: 'low', text: 'Low' })
  );

  const error = el('p', { class: 'field__error' });

  const submit = el('button', { class: 'btn btn--primary', type: 'submit', text: 'Send email' });

  const form = el('form', { class: 'card', onsubmit: (event) => {
    event.preventDefault();

    const recipients = splitAddresses(to.value);
    if (!recipients.length) { error.textContent = 'At least one recipient is required.'; return; }
    error.textContent = '';

    const payload = {
      to: recipients,
      cc: splitAddresses(cc.value),
      bcc: splitAddresses(bcc.value),
      subject: subject.value.trim() || '(no subject)',
      body: body.value
    };
    if (replyTo.value.trim()) payload.replyTo = replyTo.value.trim();
    if (from.value.trim()) payload.from = from.value.trim();
    if (priority.value) payload.priority = priority.value;
    if (format.value !== 'auto') payload.isHtml = format.value === 'html';

    withBusy(submit, async () => {
      try {
        await api.sendMail(payload);
        toast(`Sent to ${recipients.join(', ')}`, 'success');
        body.value = '';
        subject.value = '';
      } catch (failure) {
        toastError(failure);
      }
    });
  } },
    el('div', { class: 'card__body', style: { display: 'grid', gap: 'var(--space-4)' } },
      field('To', to, 'Comma, semicolon or newline separated.'),
      el('div', { class: 'form-grid form-grid--2' }, field('Cc', cc), field('Bcc', bcc)),
      el('div', { class: 'form-grid form-grid--2' },
        field('Reply-to', replyTo),
        field('From override', from, `Defaults to ${current.fromAddress}`)
      ),
      field('Subject', subject),
      field('Body', body),
      el('div', { class: 'form-grid form-grid--2' }, field('Format', format), field('Priority', priority)),
      error
    ),
    el('div', { class: 'card__foot' }, submit)
  );

  return el('section', { class: 'view' },
    el('header', { class: 'view__head' },
      el('div', {},
        el('span', { class: 'eyebrow', text: 'Compose' }),
        el('h1', { class: 'view__title', text: 'Send a test email' }),
        el('p', { class: 'view__sub' }, 'Delivered with the ',
          el('span', { class: 'mono', text: current.fromAddress }),
          ' client key via ',
          el('span', { class: 'mono', text: `${current.smtpHost}:${current.smtpPort}` }),
          '. The attempt is recorded in the mail log either way.')
      )
    ),
    form
  );
}
