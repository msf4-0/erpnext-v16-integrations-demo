/**
 * Diagnostic snapshot of the planner UI: what actually rendered?
 * Prints title, visible text, selector counts and saves a screenshot.
 */
import { chromium } from 'playwright-core';

const BASE = process.env.PLANNER_UI || 'http://localhost:3001';
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';

const browser = await chromium.launch({ executablePath: CHROME, headless: true, args: ['--no-sandbox'] });
const page = await browser.newPage({ viewport: { width: 1800, height: 1000 } });
const consoleLines = [];
page.on('console', (m) => consoleLines.push(`${m.type()}: ${m.text()}`.slice(0, 200)));
page.on('pageerror', (e) => consoleLines.push(`pageerror: ${String(e).slice(0, 300)}`));

await page.goto(BASE, { waitUntil: 'networkidle', timeout: 90000 }).catch((e) => consoleLines.push('goto: ' + e.message));
await page.waitForTimeout(4000);

const info = await page.evaluate(() => {
    const count = (sel) => document.querySelectorAll(sel).length;
    const buttons = Array.from(document.querySelectorAll('button')).map((b) => (b.innerText || '').trim()).filter(Boolean).slice(0, 25);
    return {
        title: document.title,
        url: location.href,
        text: (document.body.innerText || '').replace(/\s+/g, ' ').slice(0, 600),
        counts: {
            'td.matrix-day-cell': count('td.matrix-day-cell'),
            '.card-jobcard': count('.card-jobcard'),
            '.card-workorder': count('.card-workorder'),
            '.prod-card': count('.prod-card'),
            '.matrix-row': count('.matrix-row'),
            '.fc-event': count('.fc-event'),
            table: count('table')
        },
        buttons
    };
});

await page.screenshot({ path: 'planner-diagnostic.png', fullPage: false });
console.log(JSON.stringify({ ...info, console: consoleLines.slice(0, 20) }, null, 2));
await browser.close();
