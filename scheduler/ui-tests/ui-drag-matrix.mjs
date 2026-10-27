/**
 * Real-browser test for the planner's drag-and-drop.
 *
 * Runs against the live planner (http://localhost:3001) in headless Chrome and
 * proves the two things that were broken:
 *
 *   1. Job Cards are rendered as their own draggable cards (they used to be
 *      filtered out, so nothing JC-shaped existed to drag).
 *   2. Dragging a Job Card card issues
 *      `PUT /api/schedule/sync-reschedule {type:"jobcard"}` and the planner
 *      answers 2xx.
 *
 * Prints one JSON blob so the caller can assert on it:
 *   { ok, jcCards, woCards, drag: { jc, requestBody, status, toast } }
 *
 * Usage: node ui-drag-check.mjs
 */
import { chromium } from 'playwright-core';

const BASE = process.env.PLANNER_UI || 'http://localhost:3001';
const CHROME = process.env.CHROME_PATH || 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';

const browser = await chromium.launch({
    executablePath: CHROME,
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage']
});

const result = { ok: false, jcCards: 0, woCards: 0, drag: null, errors: [] };

try {
    const context = await browser.newContext({ viewport: { width: 1800, height: 1000 } });
    const page = await context.newPage();

    const dragRequests = [];
    page.on('request', (request) => {
        if (request.url().includes('/schedule/sync-reschedule')) {
            dragRequests.push({ method: request.method(), body: request.postData() || '' });
        }
    });
    const dragResponses = [];
    page.on('response', async (response) => {
        if (response.url().includes('/schedule/sync-reschedule')) {
            dragResponses.push({ status: response.status() });
        }
    });
    page.on('pageerror', (err) => result.errors.push(String(err).slice(0, 200)));

    await page.goto(BASE, { waitUntil: 'domcontentloaded', timeout: 90000 });

    // The app remembers the last tab; force the matrix board.
    const matrixTab = page.locator('button, a, [role="tab"]').filter({ hasText: /matrix|board/i }).first();
    if (await matrixTab.count()) {
        await matrixTab.click().catch(() => {});
    }

    await page.waitForSelector('td.matrix-day-cell', { timeout: 60000 });
    await page.waitForTimeout(2500); // let /api/schedule settle

    result.jcCards = await page.locator('.card-jobcard').count();
    result.woCards = await page.locator('.card-workorder').count();

    if (result.jcCards === 0) {
        throw new Error('no .card-jobcard rendered - Job Cards are still not draggable events');
    }

    // Find a station row that holds a Job Card and an empty cell after it.
    const rows = page.locator('tr.matrix-row');
    const rowCount = await rows.count();
    let attempted = null;

    for (let i = 0; i < rowCount && !attempted; i++) {
        const row = rows.nth(i);
        if ((await row.locator('.card-jobcard').count()) === 0) continue;

        const station = (await row.locator('.station-row-title').first().innerText().catch(() => '')).trim();
        const cells = row.locator('td.matrix-day-cell');
        const cellCount = await cells.count();

        let sourceIndex = -1;
        for (let c = 0; c < cellCount; c++) {
            if ((await cells.nth(c).locator('.card-jobcard').count()) > 0) { sourceIndex = c; break; }
        }
        if (sourceIndex < 0) continue;

        let targetIndex = -1;
        for (let c = sourceIndex + 1; c < cellCount; c++) {
            if ((await cells.nth(c).locator('.prod-card').count()) === 0) { targetIndex = c; break; }
        }
        if (targetIndex < 0) continue;

        const card = cells.nth(sourceIndex).locator('.card-jobcard').first();
        const docBadge = await card.locator('.prod-doc-id-badge').first().innerText().catch(() => '');
        const dayIndexes = await cells.evaluateAll((nodes) => nodes.map((n) => n.getAttribute('key') || n.getAttribute('data-day') || ''));

        attempted = { station, sourceIndex, targetIndex, docBadge, dayIndexes };
        await card.scrollIntoViewIfNeeded();
        await card.dragTo(cells.nth(targetIndex), { timeout: 30000 });
        await page.waitForTimeout(4000);

        // The toast is the app's own confirmation; read it if it is still visible.
        const toastText = await page
            .locator('[class*="toast"]')
            .first()
            .innerText()
            .catch(() => '');
        attempted.toast = (toastText || '').slice(0, 200);
    }

    result.drag = {
        ...attempted,
        requests: dragRequests,
        responses: dragResponses
    };

    const jcPut = dragRequests.find(
        (r) => r.method === 'PUT' && /"type"\s*:\s*"jobcard"/.test(r.body)
    );
    const okResponse = dragResponses.find((r) => r.status >= 200 && r.status < 300);
    result.ok = Boolean(jcPut && okResponse);

    await page.screenshot({ path: 'planner-after-drag.png', fullPage: false }).catch(() => {});
    await context.close();
} catch (err) {
    result.errors.push(String(err).slice(0, 400));
} finally {
    await browser.close();
}

console.log(JSON.stringify(result, null, 2));
process.exit(result.ok ? 0 : 1);
