# Upkeep household sync — specification

This is the contract between the macOS app (Swift) and the PWA (TypeScript). Both must implement it identically.

## Topology

- A **household** is one shared iCloud Drive folder (`Upkeep Household/`), shared with each member's Apple ID (edit permission).
- Every device (each Mac, each phone/tablet PWA) holds a **full replica** and has a stable random `deviceId` (UUID string).
- Every device writes **only its own** file: `Upkeep Household/devices/<deviceId>.json`.
- The household state is **the merge of all device files**. There is no master.
- A phone syncs either:
  - **LAN**: `POST https://upkeep-<person>.local:8443/api/sync` to the Mac it paired with (the Mac merges and returns its merged state), or
  - **Files**: import any number of `devices/*.json` files, merge, then export its own `devices/<deviceId>.json` (share sheet → Save to Files).

## Snapshot file

```jsonc
{
  "format": "com.bostjancigan.upkeep.household",
  "schemaVersion": 1,
  "exportedAt": "2026-09-22T10:15:00.000Z",
  "device": { "id": "…uuid…", "name": "Bostjan's MacBook Air", "platform": "mac" /* or "web" */, "personUid": "…" /* "" if none */, "build": "1.0 (1)",
              "householdId": "…uuid…" /* optional: the household this copy belongs to; older files lack it */ },
  "records": [ SyncRecord, … ],     // sorted by (kind, uid)
  "tombstones": [ Tombstone, … ]    // sorted by (kind, uid)
}
```

- Reject a file whose `format` differs (`notASnapshot`) or whose `schemaVersion` is greater than supported (`newerVersion`). Never merge those.
- **Dates** everywhere are strings: UTC ISO 8601 with exactly 3 fractional digits and `Z` (`2026-09-22T10:15:00.000Z`). Readers also accept no fractional part. Milliseconds are rounded, not truncated.
- Adding a new kind never bumps `schemaVersion`; only a change to this envelope does. (`device.householdId` is an optional addition that readers ignore if they don't know it.)

## Household identity

A household folder holds `household.json` = `{"id": "<uuid>", "createdAt": "<date>"}`, written when the household is made; a Mac reading a folder without one (made by an older version) writes it. Each device keeps the id of the household its copy belongs to — a Mac from its folder on every round, a phone from each Mac reply — and puts it in `device.householdId`. It keeps one household's copy from being merged into another's, which would bring every person, item and task in as a second copy, since a new household's records all have new uids:
- A Mac skips a device file in its folder whose `householdId` names another household (shown as "From another household — not merged").
- A phone importing files skips one from another household. *Merge from File…* on a Mac is deliberate: it merges, and says the file came from another household.
- A phone syncing over the LAN is checked first (below).
- A Mac that no longer has a file in the folder is gone — reset, replaced, or from an earlier household: after a round that read every file, its `mac` record is deleted (a Mac that's still here simply writes its record again).

### SyncRecord

```jsonc
{ "kind": "task", "uid": "…", "modifiedAt": "<date>", "modifiedBy": "<deviceId>", "data": { … } }
```

### Tombstone

```jsonc
{ "kind": "task", "uid": "…", "deletedAt": "<date>", "deletedBy": "<deviceId>" }
```

## Merge (identical on every device)

Input: any number of snapshots (local state included). Output: one record set + one tombstone set.

1. **Tombstones**: union keyed by `uid`; for duplicates keep the one with the greater `deletedAt` (tie: greater `deletedBy` string).
2. **Records**: keyed by `uid`; the winner is the one with the greater `modifiedAt`; tie → greater `modifiedBy`; still tied → greater canonical `data` text. All string comparisons are plain code-unit order.
3. A record is **removed** if a tombstone for its uid exists with `deletedAt >= modifiedAt`. (A record re-created later than the tombstone survives; the tombstone stays.)
4. **Missing ≠ deleted.** A record absent from some file is not deleted. Only tombstones delete.
5. **Unknown kinds** (from newer builds) are merged by the same rules and **kept and re-exported verbatim**.
6. Tombstones older than 365 days (by `deletedAt`, relative to now) may be dropped on export.
7. After merge, **derived fields are recomputed** locally (see `task` below). Derived fields are never part of `data`.

Merge is commutative, associative and idempotent.

## Clock (hybrid logical clock)

Every device keeps `maxSeen` = the greatest `modifiedAt`/`deletedAt` it has ever merged or written (persisted).
Stamping a local change: `t = max(now, maxSeen + 1 ms)`; `maxSeen = t`. So a device with a slow clock can't write an edit that loses to data it has already seen.

## Stamping rules

- **Canonical data** = `data` serialised with keys sorted recursively, no whitespace, whole numbers without a fraction, dates as the ISO ms strings above. Change detection compares canonical text.
- Writers always emit **every** key of a kind (`null` for absent optional dates) — never omit keys.
- Unknown keys inside a known kind (added by a newer build) are **preserved**: store the incoming `data` and write it back with known fields overlaid.
- Don't clamp or normalise incoming values when reading; only when the user edits.

- A record's `modifiedAt/modifiedBy` change **only when its `data` changes** (compare canonical data to what was last stamped). Relationship-only changes that don't alter `data` don't stamp.
- Deleting a record writes a tombstone. Deleting a `homeItem` also deletes (and tombstones) its tasks and their logs; deleting a `task` also deletes its logs.
- Applying merged records must **not** re-stamp them.
- **Restore from backup**: replace the store with the backup's records, re-stamp **every** record with the current clock and this device, and write tombstones for every local record not present in the backup — so the restore propagates instead of being overridden.

## Kinds (schema v1)

All strings default to `""`; `null` means absent for optional dates.

### `person`
```jsonc
{
  "name": "Ana",
  "colorKey": "teal",                 // TileColor raw value
  "choreDays": "17",                  // Weekdays digits: the days this person does chores. "" = any day
  "reminders": {
    "nagHours": 3,                    // remind every N hours
    "activeStart": 9, "activeEnd": 21,// hours, inclusive window
    "remindDays": "1234567",          // Calendar weekdays 1=Sun…7=Sat as digit string
    "workEnabled": false,
    "workDays": "23456",
    "workStart": 9, "workEnd": 17,
    "silencedUntil": null             // date or null
  }
}
```

### `homeItem`
```jsonc
{ "name": "Dishwasher", "iconKey": "dishwasher", "colorKey": "blue", "notes": "", "room": "Kitchen", "createdAt": "<date>" }
```

### `task`
```jsonc
{
  "itemUid": "…",
  "title": "Clean the filter",
  "intervalValue": 1,                 // >= 1
  "intervalUnit": "month",            // day | week | month | year
  "scheduleKind": "interval",         // interval | fixedDate
  "anchorDate": null,                 // first due date (start of local day); `interval` uses it until first done
  "repeats": true,                    // fixedDate: false = one-off
  "isActive": true,                   // false = paused (or finished one-off)
  "baselineDoneAt": null,             // user-entered "last done" without a log (e.g. "I just did it")
  "snoozedUntil": null,
  "preferredDays": "17",              // Weekdays digits; "" = any day. Only for `interval` schedules
  "shiftedFrom": null,                // a one-off move: the due date it was made against…
  "shiftedTo": null,                  // …and where that one occurrence went
  "assigneeUid": "",                  // person uid, "" = everyone
  "onceAssigneeUid": null,            // a one-off hand-over of the next occurrence: person uid, "" = everyone, null = none…
  "onceAssigneeAfter": null,          // …and the `lastDoneAt` it was made after (null = never done)
  "createdAt": "<date>"
}
```

**Derived (not synced), recomputed after every merge and every local change:**

- `logs` = all `taskLog` records with `taskUid == uid`.
- `lastDoneAt` = max(`baselineDoneAt`, max(log.completedAt)) or null.
- `nextDueAt` — the schedule's own date, moved onto a preferred day, then moved by a pending shift:
  1. **Base date**:
     - `fixedDate` with `anchorDate`: `due = startOfDay(anchorDate)`; if `repeats`, for each log `completedAt` in ascending order: `due = fixedDue(after: completedAt, current: due)`.
     - else if `lastDoneAt`: `due = startOfDay(lastDoneAt) + intervalValue × intervalUnit`.
     - else: `due = startOfDay(anchorDate ?? today)`.
  2. **Snap**: `due = snap(due, preferredDays)`.
  3. **Shift**: if `shiftedFrom` and `shiftedTo` are both set and `startOfDay(shiftedFrom) == due`, then `due = startOfDay(shiftedTo)`. Otherwise the shift is inert — it can't linger past the occurrence it was made for.
- `snap(due, days)` — lands the date on the day of the week the household actually does chores:
  - No move at all when `scheduleKind == fixedDate`, when `intervalUnit == day && intervalValue < 7`, when `preferredDays` holds no weekday digit, or when `due < startOfDay(today)`. **An overdue task is never pushed forward.**
  - Otherwise try `due + k` days for `k` in `[0, 1, −1, 2, −2, 3, −3, 4, 5, 6]` in that order, skipping any day before `startOfDay(today)`, and return the first whose weekday is in `days`. Nearest first, ties taking the later day. If none matches, `due`.
  - `preferredDays` is a digit string of `Calendar` weekdays (`1` = Sunday … `7` = Saturday), the same shape as `remindDays`. Digits outside `1…7` are ignored.
- `fixedDue(after done, current due)`: with `step(k) = due + k × max(1, intervalValue) × unit`, `day = startOfDay(done)`; find k with `step(k) <= day < step(k+1)` (bounded ±10 000); `covered = (day − step(k)) <= (step(k+1) − day) ? k : k+1`; return `covered < 0 ? due : step(covered + 1)`.
- Calendar arithmetic is in the device's **local time zone** and follows Foundation's `Calendar.date(byAdding:)`: adding months/years clamps to the last valid day (Jan 31 + 1 month = Feb 28/29); weeks = 7 days; days are calendar days (DST-safe).
- `isDue = nextDueAt <= now`; `isSnoozed = snoozedUntil > now`; `needsAttention = isActive && isDue && !isSnoozed`.
- A one-off (`fixedDate`, `repeats == false`) is **finished** when `!isActive && lastDoneAt != null`.

**Mark done** (local action): create a `taskLog` (`completedAt = now`, `completedByUid = me`), set `snoozedUntil = null`, `shiftedFrom = shiftedTo = null` and `onceAssigneeUid = onceAssigneeAfter = null`, and if one-off fixed-date set `isActive = false`. Then recompute derived fields.

**Move an occurrence** (local action), the way a calendar asks it. `target = startOfDay(newDate)`, `current = startOfDay(nextDueAt)`; nothing happens when they're equal.
- *This time only*: `shiftedFrom = current`, `shiftedTo = target`.
- *This and all future*, only when the series has something lasting to change — a `fixedDate` with an `anchorDate`, a task never done yet, or one whose day of the week is kept (it already has `preferredDays`, or `suggestedDays` would give it some). Otherwise the move falls back to *this time only*: an after-last-done task that comes round rarely has nothing but its history to go on. When it does apply, clear the shift, then
  - `fixedDate` with an `anchorDate`: move `anchorDate` by the whole calendar days from `current` to `target`, so every date in the series moves with it;
  - otherwise set `preferredDays` to `target`'s weekday (only when `snap` applies to this schedule), set `anchorDate = target` when `lastDoneAt` is null, recompute `nextDueAt`, and if it still isn't `target` — a move further than snapping reaches — set `shiftedFrom` to what it landed on and `shiftedTo = target`.

A task's schedule being edited clears the shift: it belonged to a date the task no longer falls on.

**Hand over an occurrence** (local action): "can you do it this time?". Picking `uid` (`""` = everyone) for just the next occurrence:
- if `uid == assigneeUid`, the usual person takes it back: `onceAssigneeUid = onceAssigneeAfter = null`;
- otherwise `onceAssigneeUid = uid`, `onceAssigneeAfter = lastDoneAt`.

It's tied to the last completion rather than a date, so moving the occurrence or editing the schedule keeps it, and any completion ends it — including one from another device that never saw the hand-over.

**Remove a log**: delete (tombstone) it; if the task was a finished one-off and no logs/baseline remain, set `isActive = true`.

### `taskLog`
```jsonc
{ "taskUid": "…", "completedAt": "<date>", "note": "", "completedByUid": "" }
```
Logs are immutable after creation (only deleted).

## Assignment & reminders

- **Current assignee** — who has the occurrence that's due next: `onceAssigneeUid` when it isn't null and `onceAssigneeAfter` equals `lastDoneAt` (compared as the stored ISO ms strings; both null counts as equal), otherwise `assigneeUid`.
- A task is **mine** when its current assignee is `myPersonUid` or `""`.
- The calendar judges each occurrence on its own: the real one goes to the current assignee, projected repeats to `assigneeUid`.
- Reminders (Mac notifications) and badges (Mac dock/menu bar, PWA `navigator.setAppBadge`) count only **mine** tasks that `needsAttention`, using **my person's** `reminders` settings. Anyone may mark any task done.
- If `assigneeUid` or `onceAssigneeUid` names a person that no longer exists, treat it as `""`.

## Up Next's week

By Date shows this calendar week (from the locale's first weekday): overdue, today, the rest of the week, and **Done** — tasks **ticked off** this week. "Ticked off" means the newest `taskLog` (`lastCompletedAt`), never `lastDoneAt`: a last-done date entered as "I just did these" or in the task editor moves the schedule but isn't a completion, so a newly added item's tasks don't show as done. A task still due today or overdue stays in those groups whatever was ticked off earlier.

## Phone notifications (Web Push sent by the Macs)

The PWA can't schedule notifications itself, so the household's Macs send them. There's no server of our own: a Mac posts encrypted Web Push messages (RFC 8030/8291 `aes128gcm`, VAPID RFC 8292, ES256) straight to the subscription endpoint (Apple's push service), so they arrive anywhere — and a Mac can send from anywhere with internet, not just at home.

Any Mac in the household can send any phone its reminders, through four record kinds (Macs only; the PWA passes them on untouched and reads `mac`/`pushSubscription` for its Settings footer):

```jsonc
// mac — uid = the Mac's deviceId; only that Mac writes it
{ "name": "Tjaša's MacBook Air", "personUid": "…", "servesPhones": true, "phoneHost": "upkeep-tjasa.local", "sendsReminders": true }
// pushKey — uid = "household": the one VAPID key every Mac signs with (base64url raw P-256 private key)
{ "privateKey": "…" }
// pushSubscription — uid = the phone's deviceId
{ "phoneName": "Ana's iPhone", "personUid": "…", "endpoint": "https://…", "p256dh": "…", "auth": "…", "pairedMacId": "<Mac deviceId>", "createdAt": "<date>" }
// pushDelivery — uid = "sent-" + the phone's deviceId (uids are unique across kinds)
{ "lastSentSlot": "<date>", "sentBy": "<Mac deviceId>" }
```

- **One key.** A phone's subscription only accepts pushes signed with the key it was made for, and a phone has one subscription, so the household shares `pushKey`. The first Mac to need one publishes it — once it has read the household folder, so it doesn't race one already there. Anyone who shares the folder can read it. A phone checks the Mac's `/api/push/key` on every sync and re-subscribes quietly if it changed.
- **Who sends.** For each subscription, a Mac computes the same reminder slots as for its own notifications, but for **that person's** tasks and reminder settings (`Nagger.nagSlots`, `Nagger.due`):
  - the Mac the phone paired with (`pairedMacId`), while it serves phones, sends at the slot, up to 10 minutes late;
  - any other Mac with `sendsReminders` waits 5 minutes (the grace), and sends only if no `pushDelivery` for that phone shows the slot yet — up to 15 minutes late.
  Whoever sends writes `pushDelivery` and syncs at once. Each Mac also remembers locally which slot it last looked at per phone, so each slot is considered once. A slow iCloud round can occasionally mean a reminder arrives twice; the phone replaces the first (same `tag`).
- The push: `{"title", "body", "tag": "upkeep-nag", "url": "/", "badge": <count of that person's tasks needing attention>}`. Pushes are sent while a Mac is awake; a slot nobody sent in time isn't sent late.
- Turning reminders off on the phone, revoking it, or a `404`/`410` from the push service deletes the subscription (and its delivery) with tombstones, so every Mac stops.
- Upgrading from before the household key: a Mac moves the subscriptions it kept in its own settings into `pushSubscription` records (itself as `pairedMacId`) and publishes its own key if none exists, so its phones need no re-pairing.
- Notification icon: iOS ignores `icon`/`badge` in `showNotification` and draws the **installed web
  app's own icon** — the `apple-touch-icon` Safari took when the app was added to the Home Screen.
  A phone added before the icons were served keeps the old placeholder, so the cure there is to
  remove the Home Screen icon and add it again. Other platforms use `icon` (the app icon) and
  `badge` (`icons/badge-96.png`, the flat white house).
- Receiving a push also wakes the phone's service worker, which makes **one LAN sync attempt** (8 s
  timeout) — at home that keeps a phone current without being opened; away from home the fetch fails
  and nothing is written. If that sync changed anything, the phone recomputes the badge locally
  rather than trusting the count the Mac sent before it.
- The phone app edits the household just as a Mac does — items, tasks, history, people and their reminder settings — with the same local actions described above, and receives reminders.

## Per-device (never synced)

`deviceId`, `myPersonUid`, device name, household folder path (Mac), open-at-login (Mac), serve-to-phones, pairings, phone name and "also answer at upkeep.local" (Mac), the last slot looked at per phone (Mac), pairing token (PWA), `maxSeen`, UI preferences.

## LAN API (Mac → PWA, same origin `https://upkeep-<person>.local:8443`)

Each serving Mac answers at a name of its own (multicast DNS): `upkeep-<slug of its person's name>.local`, e.g. `upkeep-bostjan.local` — lower-case ASCII, accents folded, other characters `-`, at most 40; people whose names read the same get `-2`, `-3` in uid order. It's fixed the first time the Mac serves, so renaming the person doesn't strand phones; the user can change it. Versions before this used `upkeep.local`; a Mac keeps answering there too while phones set up with it remain. Development builds use `upkeep-dev-<6 random hex>.local` with a 10 s TTL and never claim a real name. The server certificate covers every name the Mac uses.

- `GET /api/ping` → `200 {"app":"upkeep","schemaVersion":1,"household":true|false}` (no auth). The
  PWA pings it every 20 s while it's on screen to keep its connection indicator honest, and only
  syncs for real when something is waiting or the last round trip is over a minute old.
- `POST /api/sync` with `Authorization: Bearer <token>`, body = the phone's snapshot (as above, `platform: "web"`).
  - `401` if the token is unknown or revoked.
  - `409 {"error":"updateRequired","schemaVersion":N}` if the phone's `schemaVersion` < the Mac's.
  - `409 {"error":"otherHousehold","household":"<Mac's name>"}` if the phone's copy belongs to another household; nothing is merged. The Mac decides (`HouseholdCheck`): a Mac in no household, a phone naming the Mac's `householdId`, an empty phone or a Mac with no records → merge; otherwise merge only if the two copies share at least one record or tombstone uid (an older phone that doesn't say, or a household whose id was made again), else refuse. The phone then asks its user to **replace** its copy: records, tombstones, "who am I" and its reminders go, its device id, name and pairing stay, and it syncs the Mac's household in their place. Nothing on the Mac changes.
  - `422 {"error":"newerVersion"}` if the phone's is newer.
  - `200` body = the Mac's snapshot **after** merging the phone's (its full merged state), with the Mac's `householdId` in `device`. The phone merges it into its own replica and keeps the id.
- Pairing: the Mac shows a QR for `https://upkeep-<person>.local:8443/#pair=<token>`. The PWA stores the token and removes the fragment from the URL. The Mac notes the host each phone syncs at.
- `GET /api/push/key` (Bearer) → `200 {"publicKey": "<base64url uncompressed P-256 VAPID key>"}` — the household's key.
- `POST /api/push/subscribe` (Bearer) body `{"deviceId", "personUid", "subscription": PushSubscription.toJSON()}` → `204`. Writes that phone's `pushSubscription`, with this Mac as `pairedMacId`.
- `POST /api/push/unsubscribe` (Bearer) body `{"deviceId"}` → `204`.
- Static files: `index.html` and `sw.js` are served `Cache-Control: no-cache`; files under `/assets/` are `public, max-age=31536000, immutable`.
