// Stand-in for the mail-service HTTP API, used to exercise the admin console
// without a database. Serves public/ as-is and answers the endpoints the
// console calls with fixed fixtures.
//
//   node test/support/mock_api.mjs [port]

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../public');
export const MASTER_KEY = 'test-master-key';
export const CLIENT_KEY = 'a1b2c3d4e5f60718293a4b5c6d7e8f901122334455667788990aabbccddeeff0';

const ORGS = [
  { id: 1, name: 'Acme Corporation', slug: 'acme-corporation', clientsCount: 2, logsCount: 412, createdAt: '2026-02-11 09:12:00' },
  { id: 2, name: 'Globex', slug: 'globex', clientsCount: 1, logsCount: 58, createdAt: '2026-04-02 14:31:00' },
  { id: 3, name: 'Initech Systems', slug: 'initech-systems', clientsCount: 0, logsCount: 0, createdAt: '2026-07-19 18:02:00' }
];

const CLIENTS = [
  { id: 1, organizationId: 1, organizationName: 'Acme Corporation', organizationSlug: 'acme-corporation',
    apiKey: CLIENT_KEY, smtpHost: 'smtp.mailgun.org', smtpPort: 587, smtpUser: 'postmaster@mg.acme.com',
    fromAddress: 'no-reply@acme.com', logsCount: 380, botsCount: 2, createdAt: '2026-02-11 09:20:00' },
  { id: 2, organizationId: 1, organizationName: 'Acme Corporation', organizationSlug: 'acme-corporation',
    apiKey: 'ff00112233445566778899aabbccddeeff00112233445566778899aabbccddee',
    smtpHost: 'smtp.sendgrid.net', smtpPort: 465, smtpUser: 'apikey',
    fromAddress: 'billing@acme.com', logsCount: 32, botsCount: 0, createdAt: '2026-03-05 11:02:00' },
  { id: 3, organizationId: 2, organizationName: 'Globex', organizationSlug: 'globex',
    apiKey: '9988776655443322110099887766554433221100998877665544332211009988',
    smtpHost: 'mail.globex.io', smtpPort: 25, smtpUser: 'svc-notify',
    fromAddress: 'alerts@globex.io', logsCount: 58, botsCount: 1, createdAt: '2026-04-02 15:00:00' }
];

const SUBJECTS = ['Password reset', 'Invoice #2200', 'Deployment finished', 'Weekly digest'];
const LOGS = Array.from({ length: 140 }, (_, i) => {
  const failed = i % 7 === 3;
  return {
    id: 1000 - i,
    clientId: (i % 3) + 1,
    organizationId: i % 3 === 2 ? 2 : 1,
    organizationName: i % 3 === 2 ? 'Globex' : 'Acme Corporation',
    fromAddress: CLIENTS[i % 3].fromAddress,
    toAddress: [`user${i}@example.com`],
    cc: [], bcc: [], replyTo: null, priority: i % 11 === 0 ? 'high' : null,
    subject: SUBJECTS[i % 4],
    status: failed ? 'failed' : 'sent',
    error: failed ? '535 5.7.8 Authentication credentials invalid' : null,
    createdAt: `2026-08-${String(28 - (i % 20)).padStart(2, '0')} ${String(i % 24).padStart(2, '0')}:00:00`
  };
});

const BOTS = [
  { id: 11, name: 'acme-support', botUsername: 'acme_support_bot', botId: 7712345, isEnabled: true,
    isDefault: true, lastError: null, lastSeen: '2026-08-31 10:44:00', createdAt: '2026-05-28 21:00:00', updatedAt: '2026-08-31 10:44:00' },
  { id: 12, name: 'acme-alerts', botUsername: 'acme_alerts_bot', botId: 7798765, isEnabled: false,
    isDefault: false, lastError: 'Conflict: terminated by other getUpdates request',
    lastSeen: '2026-08-29 08:10:00', createdAt: '2026-06-14 12:00:00', updatedAt: '2026-08-29 08:10:00' }
];

const COMMANDS = [
  { id: 21, botId: 11, command: 'status', description: 'Show current system status',
    handlerUrl: 'https://app.acme.com/telegram/status', hasHandlerSecret: true, isEnabled: true,
    createdAt: '2026-05-28 21:05:00', updatedAt: '2026-05-28 21:05:00' },
  { id: 22, botId: 11, command: 'help', description: 'List available commands',
    handlerUrl: null, hasHandlerSecret: false, isEnabled: false,
    createdAt: '2026-05-29 09:00:00', updatedAt: '2026-06-01 09:00:00' }
];

const CHATS = [
  { id: 31, botId: 11, chatId: -1001234567890, title: 'Acme Ops', chatType: 'supergroup', createdAt: '2026-06-02 10:00:00' },
  { id: 32, botId: 11, chatId: 55512345, title: 'Bekzat', chatType: 'private', createdAt: '2026-06-09 17:22:00' }
];

const MESSAGES = [
  { id: 41, botId: 11, direction: 'inbound', chatId: 55512345, telegramMessageId: 901, userId: 55512345,
    username: 'bekzat', text: '/status', parseMode: null, status: 'received', errorMessage: null, createdAt: '2026-08-31 10:40:00' },
  { id: 42, botId: 11, direction: 'outbound', chatId: 55512345, telegramMessageId: 902, userId: null,
    username: null, text: 'All systems nominal.', parseMode: null, status: 'sent', errorMessage: null, createdAt: '2026-08-31 10:40:02' },
  { id: 43, botId: 11, direction: 'outbound', chatId: -1001234567890, telegramMessageId: null, userId: null,
    username: null, text: 'Deploy failed on web-03', parseMode: 'HTML', status: 'failed',
    errorMessage: 'Bad Request: chat not found', createdAt: '2026-08-31 09:15:00' }
];

const STATS = {
  organizations: ORGS.length,
  clients: CLIENTS.length,
  mail: { total: 470, sent: 438, failed: 32, last24h: 61 },
  telegram: { bots: 3, enabled_bots: 2, messages: 128 }
};

const MIME = { html: 'text/html', css: 'text/css', js: 'text/javascript', json: 'application/json' };

function json(res, payload, status = 200) {
  const body = JSON.stringify(payload);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

function serveStatic(res, pathname) {
  const rel = ['/', '/ui', '/ui/'].includes(pathname) ? '/ui/index.html' : pathname;
  const target = path.normalize(path.join(ROOT, rel));
  if (!target.startsWith(ROOT) || !fs.existsSync(target) || !fs.statSync(target).isFile()) {
    return json(res, { error: 'Not found' }, 404);
  }
  const body = fs.readFileSync(target);
  const type = MIME[target.split('.').pop()] || 'application/octet-stream';
  res.writeHead(200, { 'Content-Type': `${type}; charset=utf-8`, 'Content-Length': body.length });
  res.end(body);
}

// Signs the browser in without going through the lock screen, so a test can
// deep-link straight into a view.
function seed(res, to) {
  const page = '<!doctype html><meta charset=utf-8><script>'
    + `localStorage.setItem('mailsvc.masterKey',${JSON.stringify(MASTER_KEY)});`
    + `sessionStorage.setItem('mailsvc.masterKey',${JSON.stringify(MASTER_KEY)});`
    + `location.replace(${JSON.stringify(to)});</script>`;
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(page);
}

function filterLogs(query) {
  let items = LOGS;
  if (query.get('organization_id')) items = items.filter((l) => String(l.organizationId) === query.get('organization_id'));
  if (query.get('client_id')) items = items.filter((l) => String(l.clientId) === query.get('client_id'));
  if (query.get('status')) items = items.filter((l) => l.status === query.get('status'));
  const q = (query.get('q') || '').toLowerCase();
  if (q) items = items.filter((l) => l.subject.toLowerCase().includes(q) || l.toAddress.join(' ').toLowerCase().includes(q));
  return items;
}

export function createServer() {
  return http.createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const { pathname, searchParams } = url;
    const key = req.headers['x-api-key'];

    if (pathname === '/__seed') return seed(res, searchParams.get('to') || '/ui/');

    if (req.method === 'GET' && pathname.startsWith('/admin')) {
      if (key !== MASTER_KEY) return json(res, { error: 'Invalid master API key' }, 403);
      if (pathname === '/admin/stats') return json(res, STATS);
      if (pathname === '/admin/organizations') return json(res, { organizations: ORGS });
      if (pathname === '/admin/clients') {
        const org = searchParams.get('organization_id');
        return json(res, { clients: org ? CLIENTS.filter((c) => String(c.organizationId) === org) : CLIENTS });
      }
      if (pathname === '/admin/logs') {
        const items = filterLogs(searchParams);
        const limit = Number(searchParams.get('limit') || 100);
        const offset = Number(searchParams.get('offset') || 0);
        return json(res, { logs: items.slice(offset, offset + limit), total: items.length, limit, offset });
      }
      return json(res, { error: 'Not found' }, 404);
    }

    if (req.method === 'GET' && pathname.startsWith('/telegram')) {
      if (!CLIENTS.some((c) => c.apiKey === key)) return json(res, { error: 'Invalid API key' }, 403);
      if (pathname === '/telegram/bots') return json(res, { bots: BOTS });
      if (pathname === '/telegram/commands') return json(res, { commands: COMMANDS });
      if (pathname === '/telegram/chats') return json(res, { chats: CHATS });
      if (pathname === '/telegram/messages') return json(res, { messages: MESSAGES });
      return json(res, { error: 'Not found' }, 404);
    }

    if (req.method === 'POST') {
      if (pathname === '/config/test') return json(res, { success: true, message: 'Connection successful' });
      if (pathname === '/config') return json(res, { api_key: `n3w${'0'.repeat(61)}` }, 201);
      if (pathname === '/organizations') return json(res, { organization: ORGS[0] }, 201);
      if (pathname === '/send') return json(res, { message: 'Email sent successfully' });
      if (pathname === '/telegram/bots/test') return json(res, { success: true, username: 'demo_bot', botId: 1 });
      return json(res, { message: 'ok' }, 201);
    }

    if (req.method === 'PATCH') return json(res, { message: 'updated' });
    if (req.method === 'DELETE') return json(res, { message: 'deleted' });

    return serveStatic(res, pathname);
  });
}

// Run standalone: node test/support/mock_api.mjs [port]
if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const port = Number(process.argv[2] || 8117);
  createServer().listen(port, '127.0.0.1', () => console.log(`mock api on http://127.0.0.1:${port}`));
}
