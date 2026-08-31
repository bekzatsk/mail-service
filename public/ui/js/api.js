// Thin fetch wrapper around the mail-service HTTP API.
// Two credential scopes exist: the master key (admin endpoints) and a
// per-client API key (send / telegram endpoints).

export class ApiError extends Error {
  constructor(message, status, payload) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.payload = payload;
  }
}

async function request(path, { method = 'GET', body, apiKey } = {}) {
  const headers = {};
  if (apiKey) headers['X-Api-Key'] = apiKey;
  if (body !== undefined) headers['Content-Type'] = 'application/json';

  let response;
  try {
    response = await fetch(path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body)
    });
  } catch (cause) {
    throw new ApiError('Network error — is the service running?', 0, { cause: String(cause) });
  }

  const raw = await response.text();
  let data = null;
  if (raw) {
    try {
      data = JSON.parse(raw);
    } catch {
      data = { error: raw.slice(0, 400) };
    }
  }

  if (!response.ok) {
    const message = data?.error || `HTTP ${response.status}`;
    throw new ApiError(data?.details ? `${message} — ${data.details}` : message, response.status, data);
  }

  return data;
}

function query(params) {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params || {})) {
    if (value === undefined || value === null || value === '') continue;
    search.set(key, value);
  }
  const string = search.toString();
  return string ? `?${string}` : '';
}

// ── Master-key scope ────────────────────────────────────────────────

export function admin(masterKey) {
  const call = (path, options) => request(path, { ...options, apiKey: masterKey });

  return {
    verify:        () => call('/admin/stats'),
    stats:         () => call('/admin/stats'),

    organizations: () => call('/admin/organizations'),
    createOrganization: (body) => call('/organizations', { method: 'POST', body }),
    updateOrganization: (id, body) => call(`/admin/organizations/${id}`, { method: 'PATCH', body }),
    deleteOrganization: (id) => call(`/admin/organizations/${id}`, { method: 'DELETE' }),

    clients:       (params) => call(`/admin/clients${query(params)}`),
    client:        (id) => call(`/admin/clients/${id}`),
    createClient:  (body) => call('/config', { method: 'POST', body }),
    updateClient:  (id, body) => call(`/admin/clients/${id}`, { method: 'PATCH', body }),
    deleteClient:  (id) => call(`/admin/clients/${id}`, { method: 'DELETE' }),
    rotateClientKey: (id) => call(`/admin/clients/${id}/rotate-key`, { method: 'POST' }),
    testClient:    (id) => call(`/admin/clients/${id}/test`, { method: 'POST' }),
    testSmtp:      (body) => call('/config/test', { method: 'POST', body }),

    logs:          (params) => call(`/admin/logs${query(params)}`)
  };
}

// ── Client-key scope ────────────────────────────────────────────────

export function client(apiKey) {
  const call = (path, options) => request(path, { ...options, apiKey });

  return {
    sendMail:      (body) => call('/send', { method: 'POST', body }),

    bots:          () => call('/telegram/bots'),
    testBotToken:  (botToken) => call('/telegram/bots/test', { method: 'POST', body: { botToken } }),
    createBot:     (body) => call('/telegram/bots', { method: 'POST', body }),
    updateBot:     (id, body) => call(`/telegram/bots/${id}`, { method: 'PATCH', body }),
    deleteBot:     (id) => call(`/telegram/bots/${id}`, { method: 'DELETE' }),
    syncCommands:  (id) => call(`/telegram/bots/${id}/sync-commands`, { method: 'POST' }),

    webhookInfo:    (id) => call(`/telegram/bots/${id}/webhook`),
    enableWebhook:  (id, body) => call(`/telegram/bots/${id}/webhook`, { method: 'POST', body }),
    disableWebhook: (id) => call(`/telegram/bots/${id}/webhook`, { method: 'DELETE' }),

    chats:         (params) => call(`/telegram/chats${query(params)}`),
    createChat:    (body) => call('/telegram/chats', { method: 'POST', body }),
    deleteChat:    (id) => call(`/telegram/chats/${id}`, { method: 'DELETE' }),

    commands:      (params) => call(`/telegram/commands${query(params)}`),
    createCommand: (body) => call('/telegram/commands', { method: 'POST', body }),
    updateCommand: (id, body) => call(`/telegram/commands/${id}`, { method: 'PATCH', body }),
    deleteCommand: (id) => call(`/telegram/commands/${id}`, { method: 'DELETE' }),

    messages:      (params) => call(`/telegram/messages${query(params)}`),
    sendMessage:   (body) => call('/telegram/messages', { method: 'POST', body })
  };
}
