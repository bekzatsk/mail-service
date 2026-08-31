// Admin console smoke test.
//
// The console has no build step, so nothing catches a broken module or a
// mis-wired view until a browser loads it. This does that in CI: boots the mock
// API, walks every route, and fails on any uncaught error, any missing content,
// or any horizontal overflow.
//
//   node test/ui_smoke_test.mjs
//
// Requires playwright with chromium. In CI:
//   npm i --no-save playwright && npx playwright install --with-deps chromium

import { chromium } from 'playwright';
import { createServer, MASTER_KEY } from './support/mock_api.mjs';

const PORT = Number(process.env.SMOKE_PORT || 8117);
const BASE = `http://127.0.0.1:${PORT}`;
const BREAKPOINTS = [320, 375, 768, 1024, 1440, 1920];

const failures = [];
const check = (label, ok, detail = '') => {
  if (!ok) failures.push(`${label}${detail ? ` — ${detail}` : ''}`);
  console.log(`  ${ok ? 'ok  ' : 'FAIL'}  ${label}${detail && !ok ? ` — ${detail}` : ''}`);
};

const server = createServer();
await new Promise((resolve) => server.listen(PORT, '127.0.0.1', resolve));
console.log(`mock api on ${BASE}\n`);

const browser = await chromium.launch();

try {
  // ── The console boots, rejects a wrong key, accepts the right one ──
  console.log('Lock screen');
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await context.newPage();

  const pageErrors = [];
  page.on('pageerror', (error) => pageErrors.push(error.message));
  page.on('requestfailed', (request) => {
    // The wrong-key probe below is a deliberate 403; only transport failures matter.
    if (request.failure()?.errorText) pageErrors.push(`${request.url()} ${request.failure().errorText}`);
  });

  await page.goto(`${BASE}/ui/`, { waitUntil: 'networkidle' });
  check('lock screen renders a key field', await page.locator('input[type=password]').count() === 1);

  await page.fill('input[type=password]', 'not-the-master-key');
  await page.click('button[type=submit]');
  await page.waitForTimeout(600);
  const rejection = (await page.locator('.field__error').first().textContent()) || '';
  check('a wrong key is rejected with a message', rejection.length > 0, JSON.stringify(rejection));
  check('a wrong key does not unlock the console', await page.locator('.shell').count() === 0);

  await page.fill('input[type=password]', MASTER_KEY);
  await page.click('button[type=submit]');
  await page.waitForSelector('.shell', { timeout: 15000 });
  check('the master key unlocks the console', true);

  // ── Every view renders its own content ──
  console.log('\nViews');
  const VIEWS = [
    ['dashboard', '.stat', 6],
    ['organizations', '.orgrow', 3],
    ['clients', '.table tbody tr', 3],
    ['logs', '.table tbody tr', 50],
    ['telegram', '.tabs button.tab', 4],
    ['send', 'form.card', 1]
  ];

  for (const [route, selector, expected] of VIEWS) {
    await page.goto(`${BASE}/ui/#/${route}`, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector(selector, { timeout: 15000 });
    await page.waitForTimeout(300);
    const count = await page.locator(selector).count();
    check(`${route}: renders ${expected}× ${selector}`, count === expected, `got ${count}`);

    const navLabel = (await page.locator(".nav__item[aria-current='page']").textContent()) || '';
    const crumb = (await page.locator('.header__crumbs strong').textContent()) || '';
    check(`${route}: sidebar and breadcrumb follow the route`,
      navLabel.toLowerCase().includes(crumb.split(' ')[0]), `nav=${navLabel} crumb=${crumb}`);
  }

  // ── Telegram sub-panels ──
  console.log('\nTelegram panels');
  await page.goto(`${BASE}/ui/#/telegram`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.tabs button.tab');
  for (const [label, selector, expected] of [
    ['Commands', '.table tbody tr', 2],
    ['Chats', '.table tbody tr', 2],
    ['Messages', '.msg', 3]
  ]) {
    await page.click(`button.tab:text-is("${label}")`);
    await page.waitForSelector(selector, { timeout: 15000 });
    const count = await page.locator(selector).count();
    check(`telegram/${label.toLowerCase()}: renders ${expected} row(s)`, count === expected, `got ${count}`);
  }

  // ── A modal opens, closes on Escape, and a key can be revealed ──
  console.log('\nInteractions');
  await page.goto(`${BASE}/ui/#/clients`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.table tbody tr');
  await page.click('button:text-is("+ Issue client key")');
  await page.waitForSelector('.modal', { timeout: 15000 });
  check('the new-client modal opens with its fields', await page.locator('.modal .input, .modal .select').count() >= 6);
  await page.keyboard.press('Escape');
  await page.waitForTimeout(300);
  check('Escape closes the modal', await page.locator('.modal').count() === 0);

  await page.click('.keychip button:text-is("Show")');
  const revealed = ((await page.locator('.keychip__value--revealed').first().textContent()) || '').trim();
  check('a client key reveals in full', revealed.length === 64, `length ${revealed.length}`);

  await context.close();

  // ── Nothing overflows horizontally at any supported width ──
  console.log('\nResponsive');
  for (const width of BREAKPOINTS) {
    const narrow = await browser.newContext({ viewport: { width, height: 900 } });
    const p = await narrow.newPage();
    p.on('pageerror', (error) => pageErrors.push(`${width}px: ${error.message}`));
    await p.goto(`${BASE}/__seed?to=${encodeURIComponent('/ui/#/dashboard')}`, { waitUntil: 'networkidle' });
    await p.waitForSelector('.stat', { timeout: 15000 });

    const overflowing = [];
    for (const [route, selector] of VIEWS.map(([r, s]) => [r, s])) {
      await p.goto(`${BASE}/ui/#/${route}`, { waitUntil: 'domcontentloaded' });
      await p.waitForSelector(selector, { timeout: 15000 });
      await p.waitForTimeout(250);
      const over = await p.evaluate(() =>
        document.documentElement.scrollWidth - document.documentElement.clientWidth);
      if (over > 1) overflowing.push(`${route}:+${over}px`);
    }
    check(`${width}px: no horizontal overflow on any view`, overflowing.length === 0, overflowing.join(', '));
    await narrow.close();
  }

  console.log('\nRuntime errors');
  check('no uncaught errors or failed requests', pageErrors.length === 0, pageErrors.join(' | '));
} finally {
  await browser.close();
  server.close();
}

console.log();
if (failures.length) {
  console.log(`ui smoke: ${failures.length} check(s) FAILED`);
  failures.forEach((f) => console.log(`  - ${f}`));
  process.exit(1);
}
console.log('ui smoke: all checks pass');
