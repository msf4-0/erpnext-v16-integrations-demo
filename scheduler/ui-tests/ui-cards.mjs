/**
 * Read-only UI check: does the planner actually render draggable Job Cards?
 *
 * This is the regression guard for the real bug: the component used to map only
 * *orphaned* job cards into events, so every JC that belonged to a Work Order was
 * filtered out and the board had nothing JC-shaped to drag. Nothing is dragged or
 * written here - it only counts what the DOM shows.
 *
 * Exit 0 + {"ok":true} when the matrix shows Job Card cards AND the calendar view
 * shows Job Card events.
 */
import { chromium } from 'playwright-core';

const BASE = process.env.PLANNER_UI || 'http://localhost:3001';
const CHROME = process.env.CHROME_PATH || 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';

const browser = await chromium.launch({ executablePath: CHROME, headless: true, args: ['--no-sandbox'] });
const out = { ok: false, matrix: {}, calendar: {}, console: [] };

try {
    const page = await browser.newPage({ viewport: { width: 1800, height: 1000 } });
    page.on('console', (m) => {
        if (m.type() === 'error') out.console.push(m.text().slice(0, 160));
    });
    page.on('pageerror', (e) => out.console.push(String(e).slice(0, 160)));

    await page.goto(BASE, { waitUntil: 'domcontentloaded', timeout: 90000 });

    // ---- matrix ----
    const matrixTab = page.locator('button').filter({ hasText: /workstation matrix/i }).first();
    if (await matrixTab.count()) await matrixTab.click().catch(() => {});
    await page.waitForSelector('td.matrix-day-cell', { timeout: 60000 });
    await page.waitForTimeout(2500);

    out.matrix = {
        jobCards: await page.locator('.card-jobcard').count(),
        workOrders: await page.locator('.card-workorder').count(),
        stations: await page.locator('tr.matrix-row').count(),
        draggableJobCards: await page.locator('.card-jobcard[draggable="true"]').count()
    };

    // ---- calendar ----
    const calendarTab = page.locator('button').filter({ hasText: /calendar view/i }).first();
    if (await calendarTab.count()) await calendarTab.click().catch(() => {});
    await page.waitForTimeout(2000);
    const filter = page.locator('select.select-filter').first();
    if (await filter.count()) await filter.selectOption('jobcard').catch(() => {});
    await page.waitForTimeout(2500);

    out.calendar = {
        jobCardEvents: await page.locator('.fc-event').count()
    };

    out.ok =
        out.matrix.jobCards > 0 &&
        out.matrix.draggableJobCards > 0 &&
        out.calendar.jobCardEvents > 0 &&
        out.console.length === 0;

    await page.screenshot({ path: 'planner-ui-check.png' }).catch(() => {});
    await page.close();
} catch (err) {
    out.error = String(err).slice(0, 300);
} finally {
    await browser.close();
}

console.log(JSON.stringify(out, null, 2));
process.exit(out.ok ? 0 : 1);
