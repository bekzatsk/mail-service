// Hash router. Deep links survive reloads without any server-side rewrite,
// which matters on the Passenger/cPanel target.

const routes = new Map();
let notFound = null;
let current = null;

export function defineRoute(name, handler) {
  routes.set(name, handler);
}

export function setNotFound(handler) {
  notFound = handler;
}

export function parseHash() {
  const raw = window.location.hash.replace(/^#\/?/, '');
  const [path, search] = raw.split('?');
  const segments = path.split('/').filter(Boolean);
  return {
    name: segments[0] || 'dashboard',
    params: segments.slice(1),
    query: Object.fromEntries(new URLSearchParams(search || ''))
  };
}

export function navigate(path, { replace = false } = {}) {
  const target = `#/${String(path).replace(/^#?\/?/, '')}`;
  if (replace) {
    window.history.replaceState(null, '', target);
    window.dispatchEvent(new HashChangeEvent('hashchange'));
  } else {
    window.location.hash = target;
  }
}

export function currentRoute() {
  return current;
}

export function startRouter(onRoute) {
  const handle = () => {
    current = parseHash();
    const handler = routes.get(current.name) || notFound;
    onRoute(current, handler);
  };

  window.addEventListener('hashchange', handle);
  handle();
}
