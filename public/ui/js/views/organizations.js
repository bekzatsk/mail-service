import { adminApi, getState, refresh } from '../store.js';
import { navigate, currentRoute } from '../router.js';
import {
  el, field, openModal, confirmAction, toast, toastError,
  formatNumber, formatDate, emptyState, withBusy
} from '../ui.js';

const SLUG_PATTERN = /^[a-z0-9-]+$/;

function slugify(value) {
  return String(value).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
}

function organizationForm({ name = '', slug = '' } = {}) {
  const nameInput = el('input', { class: 'input', type: 'text', value: name,
    placeholder: 'Acme Corporation', required: true });
  const slugInput = el('input', { class: 'input input--mono', type: 'text', value: slug,
    placeholder: 'acme-corporation' });
  const error = el('p', { class: 'field__error' });

  // Slug mirrors the name until the operator edits it by hand.
  let slugTouched = Boolean(slug);
  slugInput.addEventListener('input', () => { slugTouched = true; });
  nameInput.addEventListener('input', () => {
    if (!slugTouched) slugInput.value = slugify(nameInput.value);
  });

  const body = el('div', { class: 'form-grid' },
    field('Name', nameInput),
    field('Slug', slugInput, 'Lowercase letters, digits and dashes. Used as the stable identifier.'),
    error
  );

  const read = () => {
    const values = { name: nameInput.value.trim(), slug: slugInput.value.trim() || slugify(nameInput.value) };
    if (!values.name) { error.textContent = 'Name is required.'; return null; }
    if (values.slug && !SLUG_PATTERN.test(values.slug)) {
      error.textContent = 'Slug may only contain lowercase letters, digits and dashes.';
      return null;
    }
    error.textContent = '';
    return values;
  };

  return { body, read };
}

async function openCreateDialog(onDone) {
  const form = organizationForm();

  await openModal({
    title: 'New organization',
    render: () => form.body,
    footer: ({ close }) => [
      el('button', { class: 'btn', type: 'button', text: 'Cancel', onclick: () => close(false) }),
      el('button', {
        class: 'btn btn--primary', type: 'button', text: 'Create',
        onclick: (event) => {
          const values = form.read();
          if (!values) return;
          withBusy(event.currentTarget, async () => {
            try {
              await adminApi().createOrganization(values);
              toast(`Organization “${values.name}” created`, 'success');
              close(true);
              await onDone();
            } catch (error) {
              toastError(error);
            }
          });
        }
      })
    ]
  });
}

async function openEditDialog(organization, onDone) {
  const form = organizationForm(organization);

  await openModal({
    title: `Edit ${organization.name}`,
    render: () => form.body,
    footer: ({ close }) => [
      el('button', { class: 'btn', type: 'button', text: 'Cancel', onclick: () => close(false) }),
      el('button', {
        class: 'btn btn--primary', type: 'button', text: 'Save changes',
        onclick: (event) => {
          const values = form.read();
          if (!values) return;
          withBusy(event.currentTarget, async () => {
            try {
              await adminApi().updateOrganization(organization.id, values);
              toast('Organization updated', 'success');
              close(true);
              await onDone();
            } catch (error) {
              toastError(error);
            }
          });
        }
      })
    ]
  });
}

async function removeOrganization(organization, onDone) {
  const confirmed = await confirmAction({
    title: `Delete ${organization.name}?`,
    message: `This permanently removes the organization, its ${formatNumber(organization.clientsCount)} client key(s) `
      + `and ${formatNumber(organization.logsCount)} mail log entries. Client keys stop working immediately. This cannot be undone.`,
    confirmLabel: 'Delete permanently'
  });
  if (!confirmed) return;

  try {
    await adminApi().deleteOrganization(organization.id);
    toast('Organization deleted', 'success');
    await onDone();
  } catch (error) {
    toastError(error);
  }
}

function organizationRow(organization, index, onDone) {
  const open = () => navigate(`clients?organization_id=${organization.id}`);

  return el('div', {
    class: 'orgrow', role: 'button', tabindex: '0',
    onclick: (event) => { if (!event.target.closest('button')) open(); },
    onkeydown: (event) => { if (event.key === 'Enter') open(); }
  },
    el('span', { class: 'orgrow__idx', text: String(index + 1).padStart(2, '0') }),
    el('div', { style: { minWidth: 0 } },
      el('div', { class: 'orgrow__name', text: organization.name }),
      el('div', { class: 'orgrow__slug', text: organization.slug })
    ),
    el('div', { class: 'orgrow__stats' },
      el('span', {}, el('b', { text: formatNumber(organization.clientsCount) }), ' clients'),
      el('span', {}, el('b', { text: formatNumber(organization.logsCount) }), ' logs'),
      el('span', { text: formatDate(organization.createdAt) })
    ),
    el('div', { class: 'orgrow__actions' },
      el('button', { class: 'btn btn--ghost btn--sm', type: 'button', text: 'Edit',
        onclick: () => openEditDialog(organization, onDone) }),
      el('button', { class: 'btn btn--ghost btn--sm btn--danger', type: 'button', text: 'Delete',
        onclick: () => removeOrganization(organization, onDone) })
    )
  );
}

export async function render() {
  const reload = () => refresh();
  const { organizations } = getState();

  const list = el('div', { class: 'orglist' });
  const search = el('input', { class: 'input', type: 'search', placeholder: 'Filter by name or slug…' });

  const paint = (term = '') => {
    const needle = term.trim().toLowerCase();
    const visible = needle
      ? organizations.filter((entry) =>
          entry.name.toLowerCase().includes(needle) || entry.slug.toLowerCase().includes(needle))
      : organizations;

    list.replaceChildren(
      visible.length
        ? el('div', {}, visible.map((entry, index) => organizationRow(entry, index, reload)))
        : emptyState(
            organizations.length ? 'No match' : 'No organizations yet',
            organizations.length ? 'Try a different search term.' : 'An organization is the tenant boundary — client keys and mail logs hang off it.',
            organizations.length ? null : el('button', { class: 'btn btn--primary', type: 'button',
              text: 'Create the first one', onclick: () => openCreateDialog(reload) })
          )
    );
  };

  search.addEventListener('input', () => paint(search.value));
  paint();

  if (currentRoute()?.query?.new === '1') {
    navigate('organizations', { replace: true });
    openCreateDialog(reload);
  }

  return el('section', { class: 'view' },
    el('header', { class: 'view__head' },
      el('div', {},
        el('span', { class: 'eyebrow', text: 'Tenants' }),
        el('h1', { class: 'view__title', text: 'Organizations' }),
        el('p', { class: 'view__sub', text: 'Every client key and every mail log belongs to exactly one organization.' })
      ),
      el('div', { class: 'view__actions' },
        el('button', { class: 'btn btn--primary', type: 'button', text: '+ New organization',
          onclick: () => openCreateDialog(reload) })
      )
    ),
    el('div', { class: 'toolbar' }, search,
      el('span', { class: 'toolbar__spacer' }),
      el('span', { class: 'eyebrow', text: `${formatNumber(organizations.length)} total` })
    ),
    list
  );
}
