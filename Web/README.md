# Upkeep PWA

The iPhone/iPad companion to the Upkeep Mac app. It does what the Mac does with the household: tasks
marked done (with a 5-second Undo), moved or handed to someone else this time; items added from the
same catalog (`src/modules/maintenance/templates.json`, checked against the Mac's by
`Tools/test-core.sh`); tasks, schedules, history, people and reminder settings edited. It receives
reminders as Web Push notifications sent by the Mac. Pairing, the shared folder and backups stay on
the Mac.

The Mac bundles `dist/` and serves it at `https://upkeep-<person>.local:8443` (e.g. `upkeep-bostjan.local`). The app works fully offline
(service worker + IndexedDB replica) and syncs:

- **at home**: `POST /api/sync` with the pairing token from the Mac's QR code (`#pair=<token>`),
  automatically on open, when the app comes back to the foreground, ~1 s after a change, and on a
  20-second heartbeat that pings (`GET /api/ping`) rather than shipping a snapshot, so the
  connection indicator in the navigation bar stays honest;
- **away**: Settings › Import from Files… (pick every file in `Upkeep Household/devices/`) and
  Export to Files… (save `<deviceId>.json` back into that folder).

Away from home the app opens only from its **offline copy** (the service worker and its precache);
a Home Screen app without one shows iOS's blank white page. Settings › About › Offline Copy says
whether it's there, and a Home Screen app that has lost it warns on Up Next with a *Fix* that
downloads it again — only while the Mac answers, since the files come from the Mac. Workbox fills
the precache only while a worker installs, and the *active* worker answers every launch from its
own revisions only, so "missing" means the active worker's set (`PRECACHE_STATUS`), not any copy
of the shell. Once a launch the app repairs it quietly: an update already waiting takes over
(iOS drops waiting workers when the app is closed, so prompting alone would never get there);
otherwise the active worker downloads what it lacks (`REFILL_PRECACHE`).

The contract shared with the Swift app is [`../Docs/Sync.md`](../Docs/Sync.md).

**Demo and erase** (in every build, not just dev): seven taps on Settings › About › Upkeep unlock a
*Developer* section with *Load the Sample Household* — which erases the device first and leaves it
unpaired, so the pretend home can never reach a real Mac — and *Erase All Data on This Device*,
which takes it back to a fresh install (replica, pairing, person, push subscription, preferences).
Both live in [`src/app/demo.ts`](src/app/demo.ts); a device in demo mode says so in a banner and in
the navigation bar.

## Scripts

| Command | What it does |
|---|---|
| `npm install` | Install dependencies (Node 20.19+) |
| `npm run dev` | Dev server. Settings › Developer › Load Demo Data seeds a household |
| `npm run build` | Typecheck, then build to `dist/` (`index.html`, `sw.js`, `manifest.webmanifest`, hashed `assets/`) |
| `npm test` | Vitest (runs in `Europe/Ljubljana` so DST cases are exercised) |
| `npm run typecheck` | `tsc -b` over app, service worker, tests and config |

## Structure

```
src/
  core/                 kind-agnostic, reusable by future modules (shopping list, pantry…)
    dates.ts            ISO ms encode/decode, Foundation-style local calendar arithmetic, en-GB formatting
    clock.ts            hybrid logical clock (t = max(now, maxSeen + 1 ms))
    snapshot.ts         envelope types, validation (notASnapshot / newerVersion / damaged), canonical JSON
    merge.ts            generic merge: LWW records, tombstones, unknown kinds pass through
    registry.ts         registerCollection({kind, defaults, children}) + derived-state hooks
    db.ts               Dexie: records (by uid, kind index), tombstones, meta; stamping writer
    sync.ts             LanTransport, FilesTransport, auto-sync, pairing fragment
    status.ts           one reading of the link to the Mac (at home / syncing / away / offline)
    push.ts             Web Push subscribe/unsubscribe with the Mac
    people.ts           person kind, "who am I", assignment rules
    pwa.ts              build stamp, service-worker update helpers
    offline.ts          whether the offline copy is installed, and refilling it
  modules/maintenance/  homeItem → task → taskLog
    catalog.ts          icon keys (SVGs come from ../Upkeep/Icons, shared with the Mac)
    schedule.ts         derived fields, fixedDue, DueStatus text, describe(), household model
    actions.ts          markDone / undoMarkDone
    tile.tsx            gradient squircle icon tile
    screens/            Up Next, Items, Item detail, task row
  app/                  shell (tabs, onboarding, settings, banners, badge), shared UI
    SyncStatus.tsx      the live connection indicator in the navigation bar
  sw.ts                 service worker: precache, offline navigation, update prompt, push
test/
  fixtures/             deviceA.json, deviceB.json, merged.expected.json (shared with the Swift tests)
```

Unknown record kinds and unknown fields inside known kinds are stored verbatim and re-exported,
so data from newer builds (or modules this build doesn't have) survives a round trip.

Icons in `public/icons/` are rendered with the Mac app icon by `swift Tools/render_icons.swift .` (full-bleed for iOS, plus a maskable one).
