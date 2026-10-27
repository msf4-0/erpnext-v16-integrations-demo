# Planner UI drag tests (real Chrome, headless)

Three Node scripts that drive the live planner in a real Chrome and prove the
drag-and-drop actually persists Ã¢â‚¬â€ not that a button exists.

| Script | What it proves |
|---|---|
| `ui-diagnostic.mjs` | what the page rendered: selector counts, console errors, a screenshot. Use this first when the UI looks empty. |
| `ui-drag-matrix.mjs` | a **Job Card** card exists in the Workstation Matrix and dragging it to another day issues `PUT /api/schedule/sync-reschedule {type:"jobcard"}` Ã¢â€ â€™ 2xx |
| `ui-drag-calendar.mjs` | the same for the **Calendar** view (different handler: FullCalendar `eventDrop`) |

They only read the UI; the drag itself mutates the schedule, so put the demo back
afterwards (see below).

## Run

```powershell
cd F:\ERPNEXT\erpnext-build\scheduler\ui-tests
npm i playwright-core          # uses the system Chrome, downloads no browser
node ui-cards.mjs              # read-only: are Job Cards rendered + draggable?
node ui-drag-matrix.mjs        # -> {"ok":true, ...} and exit 0
node ui-drag-calendar.mjs
```

Environment overrides: `PLANNER_UI` (default `http://localhost:3001`),
`CHROME_PATH` (default `C:\Program Files\Google\Chrome\Application\chrome.exe`).

Both scripts print one JSON object; `ok` is only true when the app really sent a
`jobcard` PUT **and** the planner answered 2xx. A screenshot of the post-drag
state is written next to the script.

## Restoring the demo after a drag

```powershell
# put one Job Card back on its seeded window (server shifts every capacity block)
docker exec -e JC=PO-JOB00002 -e START="2026-10-27 14:10:00" -e END="2026-10-29 16:10:00" `
  comp_demo-bench-1 bash -lc 'cd /home/frappe/frappe-bench && SITE_NAME=frontend \
  ./env/bin/python /tmp/scripts/jc-shift.py'
```

`jc-shift.py` lives in `comp_demo/sandbox/scripts/`. Copy it in first:

```powershell
docker cp F:\ERPNEXT\erpnext-build\sandbox\scripts\jc-shift.py comp_demo-bench-1:/tmp/scripts/
```

## Why this exists

The Job Cards were never rendered as draggable cards: the component filtered the
event list down to *orphaned* job cards (those with no loaded Work Order), and in
this demo every Job Card belongs to a Work Order Ã¢â‚¬â€ so the matrix and calendar had
nothing JC-shaped to grab, and "Job Card drag does not work" was really "there is
no Job Card". `Scheduler.jsx` now maps every Job Card to an event (and the view
filter gained a **Job Cards** option).
