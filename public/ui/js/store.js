// Application state. Deliberately tiny: a frozen snapshot plus subscribers.
// Nothing here mutates in place — every update produces a new state object.

import { admin, client } from './api.js';

const MASTER_KEY_STORAGE = 'mailsvc.masterKey';
const SCOPE_STORAGE = 'mailsvc.clientId';

function readStoredKey() {
  return sessionStorage.getItem(MASTER_KEY_STORAGE) || localStorage.getItem(MASTER_KEY_STORAGE) || '';
}

let state = Object.freeze({
  masterKey: readStoredKey(),
  organizations: [],
  clients: [],
  selectedClientId: Number(localStorage.getItem(SCOPE_STORAGE)) || null,
  stats: null,
  loading: false
});

const listeners = new Set();

export function getState() {
  return state;
}

export function subscribe(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

function setState(patch) {
  state = Object.freeze({ ...state, ...patch });
  listeners.forEach((listener) => listener(state));
}

// ── Credentials ─────────────────────────────────────────────────────

export function saveMasterKey(key, remember) {
  sessionStorage.setItem(MASTER_KEY_STORAGE, key);
  if (remember) {
    localStorage.setItem(MASTER_KEY_STORAGE, key);
  } else {
    localStorage.removeItem(MASTER_KEY_STORAGE);
  }
  setState({ masterKey: key });
}

export function clearMasterKey() {
  sessionStorage.removeItem(MASTER_KEY_STORAGE);
  localStorage.removeItem(MASTER_KEY_STORAGE);
  setState({ masterKey: '', organizations: [], clients: [], stats: null, selectedClientId: null });
}

export function isAuthenticated() {
  return Boolean(state.masterKey);
}

// ── API accessors ───────────────────────────────────────────────────

export function adminApi() {
  return admin(state.masterKey);
}

export function selectedClient() {
  return state.clients.find((entry) => entry.id === state.selectedClientId) || null;
}

/** Client-scoped API for the currently selected client, or null if none. */
export function clientApi() {
  const current = selectedClient();
  return current ? client(current.apiKey) : null;
}

export function selectClient(clientId) {
  const id = clientId ? Number(clientId) : null;
  if (id) {
    localStorage.setItem(SCOPE_STORAGE, String(id));
  } else {
    localStorage.removeItem(SCOPE_STORAGE);
  }
  setState({ selectedClientId: id });
}

// ── Data loading ────────────────────────────────────────────────────

/** Reloads organizations, clients and stats in parallel. */
export async function refresh() {
  setState({ loading: true });
  try {
    const api = adminApi();
    const [organizations, clients, stats] = await Promise.all([
      api.organizations(),
      api.clients(),
      api.stats()
    ]);

    const list = clients.clients || [];
    const stillValid = list.some((entry) => entry.id === state.selectedClientId);

    setState({
      organizations: organizations.organizations || [],
      clients: list,
      stats,
      selectedClientId: stillValid ? state.selectedClientId : (list[0]?.id ?? null),
      loading: false
    });
  } catch (error) {
    setState({ loading: false });
    throw error;
  }
}
