/**
 * Real-browser test for the CALENDAR view's Job Card drag.
 *
 * The matrix and the FullCalendar view persist through different handlers
 * (`handleCellDrop` vs `handleFullCalendarDrop`), so both need proving.
 *
 * Targets the "Cutting" Job Card of MFG-WO-2026-00001 (PO-JOB00001) so the
 * caller can put it back with a known window afterwards.
 */
import { chromium } from 'playwright-core';

const BASE = process.env.PLANNER_UI || 'http://localhost:3001';
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';

const browser = await chromium.launch({ executablePath: CHROME, headless: true, args: ['--no-sandbox'] });
const result = { ok: false, events: 0, drag: null, errors: [] };

try {
    const page = await browser.newPage({ viewport: { width: 1800, height: 1000 } });
    const requests = [];
    const responses = [];
    page.on('request', (r) => {
        if (r.url().includes('/schedule/sync-reschedule')) requests.push({ method: r.method(), body: r.postData() || '' });
    });
    page.on('response', (r) => {
        if (r.url().includes('/schedule/sync-reschedule')) responses.push({ status: r.status() });
    });
    page.on('pageerror', (e) => result.errors.push(String(e).slice(0, 200)));

    await page.goto(BASE, { waitUntil: 'domcontentloaded', timeout: 90000 });

    await page.locator('button').filter({ hasText: /calendar view/i }).first().click();
    await page.waitForSelector('.fc-event, .fc-daygrid-day', { timeout: 60000 });

    // Show Job Cards only, so every event is a JC.
    const filter = page.locator('select.select-filter').first();
    if (await filter.count()) {
        await filter.selectOption('jobcard').catch(async () => {
            await filter.selectOption({ label: /job card/i }).catch(() => {});
        });
    }
    await page.waitForSelector('.fc-event', { timeout: 60000 });
    await page.waitForTimeout(2000);

    result.events = await page.locator('.fc-event').count();

    const events = page.locator('.fc-event');
    const count = await events.count();
    let target = null;

    for (let i = 0; i < count; i++) {
        const text = (await events.nth(i).innerText().catch(() => '')).replace(/\s+/g, ' ');
        if (/cutting/i.test(text) && /MFG-WO-2026-00001/.test(text)) {
            target = { index: i, text: text.slice(0, 120) };
            break;
        }
    }
    if (!target && count > 0) {
        target = { index: 0, text: (await events.nth(0).innerText().catch(() => '')).slice(0, 120) };
    }
    if (!target) throw new Error('no .fc-event rendered in the calendar view');

    // Its current day cell, so we can drop on a later, empty cell.
    const event = events.nth(target.index);
    const sourceDay = event.locator('xpath=ancestor::td[contains(@class,"fc-daygrid-day")][1]');
    const sourceDate = await sourceDay.getAttribute('data-date').catch(() => null);

    const days = page.locator('td.fc-daygrid-day');
    const dayCount = await days.count();
    let dayIndexes = [];
    for (let i = 0; i < dayCount; i++) dayIndexes.push(await days.nth(i).getAttribute('data-date').catch(() => null));

    const sourcePos = dayIndexes.indexOf(sourceDate);
    let dropPos = -1;
    for (let i = sourcePos + 1; i < dayCount; i++) {
        if ((await days.nth(i).locator('.fc-event').count()) === 0) { dropPos = i; break; }
    }
    if (dropPos < 0) throw new Error('no empty day cell after the event to drop onto');

    await event.scrollIntoViewIfNeeded();
    await event.dragTo(days.nth(dropPos), { timeout: 30000 });
    await page.waitForTimeout(4000);

    result.drag = {
        target,
        sourceDate,
        dropDate: dayIndexes[dropPos],
        requests,
        responses
    };

    const jcPut = requests.find((r) => r.method === 'PUT' && /"type"\s*:\s*"jobcard"/.test(r.body));
    const okResponse = responses.find((r) => r.status >= 200 && r.status < 300);
    result.ok = Boolean(jcPut && okResponse);

    await page.screenshot({ path: 'planner-calendar-drop.png', fullPage: false }).catch(() => {});
    await page.close();
} catch (err) {
    result.errors.push(String(err).slice(0, 400));
} finally {
    await browser.close();
}

console.log(JSON.stringify(result, null, 2));
process.exit(result.ok ? 0 : 1);
