// Getting changes in and out: LAN sync with the Mac, and snapshot files via the Files app.
// The round trip itself lives in `lanSync.ts`, which the service worker shares.
import { allMeta, applyMerge, deviceId, localChangeCount, onLocalChange, setMeta } from './db'
import { lanSyncOnce, ownSnapshot } from './lanSync'
import type { MergeSummary } from './merge'
import { isStandalone, refreshPushSubscription } from './push'
import { forceUpdate } from './pwa'
import { decodeSnapshot, encodeSnapshot, SnapshotError, type Snapshot } from './snapshot'

export { ownSnapshot }

async function markSynced(changesAtStart: number, key: 'lastExport' | 'lastImport', now = Date.now()) {
  await setMeta(key, now)
  // Edits made while the request was in flight still need syncing.
  if (key !== 'lastImport' && localChangeCount() === changesAtStart) await setMeta('firstUnsyncedChange', 0)
}

// MARK: LAN

/** What to say when the Mac turned this device's copy away as another household's. */
export function otherHouseholdMessage(macName: string): string {
  const mac = macName || 'your Mac'
  return `This phone still has another household’s items and people, from before ${mac} was set up again. Replace them with the household on ${mac}? Nothing on the Mac changes.`
}

export type LanStatus =
  | 'idle'
  /** A local edit is saved and waiting for its round trip — the indicator says so at once. */
  | 'pending'
  | 'syncing'
  | 'ok'
  | 'notPaired'
  | 'unreachable'
  | 'unauthorized'
  | 'macNeedsUpdate'
  /** This device still holds another household's copy; nothing was merged. */
  | 'otherHousehold'
  | 'updating'
  | 'error'

export interface LanState {
  status: LanStatus
  message?: string
  lastSummary?: MergeSummary
  /** When this state was entered, so the UI can show "Synced" for a moment. */
  at: number
}

/** After this long without a round trip, the heartbeat does a full sync instead of a ping. */
export const FULL_SYNC_AFTER_MS = 60_000

let lanState: LanState = { status: 'idle', at: 0 }
const lanListeners = new Set<() => void>()

function setLanState(next: Omit<LanState, 'at'>, now = Date.now()) {
  lanState = { ...next, at: now }
  for (const l of lanListeners) l()
}

export function getLanState(): LanState {
  return lanState
}

export function subscribeLan(listener: () => void): () => void {
  lanListeners.add(listener)
  return () => lanListeners.delete(listener)
}

async function fetchWithTimeout(input: string, init: RequestInit, ms: number): Promise<Response> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), ms)
  try {
    return await fetch(input, { ...init, signal: controller.signal })
  } finally {
    clearTimeout(timer)
  }
}

export const LanTransport = {
  async ping(): Promise<{ app: string; schemaVersion: number; household: boolean } | null> {
    try {
      const res = await fetchWithTimeout('/api/ping', { cache: 'no-store' }, 3000)
      if (!res.ok) return null
      const body = (await res.json()) as { app?: unknown; schemaVersion?: unknown; household?: unknown }
      if (body.app !== 'upkeep') return null
      return { app: 'upkeep', schemaVersion: Number(body.schemaVersion), household: body.household === true }
    } catch {
      return null
    }
  },

  /** One round trip through `lanSyncOnce`, with this app's status line and side effects. */
  async sync(): Promise<LanState> {
    if (lanState.status === 'syncing') return lanState
    if (!(await allMeta()).pairToken) {
      setLanState({ status: 'notPaired' })
      return lanState
    }
    setLanState({ status: 'syncing' })
    const outcome = await lanSyncOnce()
    switch (outcome.kind) {
      case 'ok':
        if (outcome.macName) await setMeta('macName', outcome.macName)
        setLanState({ status: 'ok', lastSummary: outcome.summary })
        // Keeps the Mac's copy of this device's push subscription (and person) fresh.
        void refreshPushSubscription()
        break
      case 'notPaired':
        setLanState({ status: 'notPaired' })
        break
      case 'unauthorized':
        setLanState({ status: 'unauthorized', message: 'This device isn’t paired any more. Enter a new pairing code from your Mac.' })
        break
      case 'updateRequired':
        setLanState({ status: 'updating', message: 'Updating Upkeep…' })
        void forceUpdate()
        break
      case 'macNeedsUpdate':
        setLanState({ status: 'macNeedsUpdate', message: 'Update Upkeep on your Mac to sync with this device.' })
        break
      case 'otherHousehold':
        if (outcome.macName) await setMeta('macName', outcome.macName)
        setLanState({ status: 'otherHousehold', message: otherHouseholdMessage(outcome.macName) })
        break
      case 'unreachable':
        setLanState({ status: 'unreachable' })
        break
      case 'error':
        setLanState({ status: 'error', message: outcome.message })
        break
    }
    return lanState
  },

  /**
   * Keeps the connection indicator honest between round trips: a ping costs nothing, a snapshot
   * doesn't. Syncs for real when the Mac has just come back, when changes are waiting, or when
   * the last round trip is getting old.
   */
  async probe(): Promise<LanState> {
    if (lanState.status === 'syncing' || lanState.status === 'pending') return lanState
    // No network at all: say so without waking the radio for a request that can't arrive.
    if (navigator.onLine === false) {
      if (lanState.status !== 'unreachable') setLanState({ status: 'unreachable' })
      return lanState
    }
    const meta = await allMeta()
    if (!meta.pairToken) {
      if (lanState.status !== 'notPaired') setLanState({ status: 'notPaired' })
      return lanState
    }
    const reply = await LanTransport.ping()
    if (!reply) {
      if (lanState.status !== 'unreachable') setLanState({ status: 'unreachable' })
      return lanState
    }
    const cold = !meta.lastLanSync || Date.now() - meta.lastLanSync > FULL_SYNC_AFTER_MS
    if (cold || meta.firstUnsyncedChange || lanState.status !== 'ok') return LanTransport.sync()
    return lanState
  },
}

/**
 * Keeps the replica — and the connection indicator — in step with the Mac: on open, when the app
 * is shown again, shortly after every edit, and on a quiet heartbeat while it's on screen.
 */
export function startAutoSync({ delayAfterChange = 1200, heartbeatMs = 20_000 } = {}): () => void {
  let timer: ReturnType<typeof setTimeout> | undefined
  const run = () => void LanTransport.sync()
  const beat = () => {
    if (document.visibilityState === 'visible') void LanTransport.probe()
  }
  const onVisible = () => {
    if (document.visibilityState === 'visible') run()
  }
  const onOffline = () => setLanState({ status: 'unreachable' })
  const unsubscribe = onLocalChange(() => {
    // Say "Saving…" the moment the tick lands, rather than after the debounce.
    if (lanState.status !== 'syncing') setLanState({ status: 'pending' })
    clearTimeout(timer)
    timer = setTimeout(run, delayAfterChange)
  })
  const heartbeat = setInterval(beat, heartbeatMs)
  document.addEventListener('visibilitychange', onVisible)
  window.addEventListener('online', run)
  window.addEventListener('offline', onOffline)
  run()
  return () => {
    clearTimeout(timer)
    clearInterval(heartbeat)
    unsubscribe()
    document.removeEventListener('visibilitychange', onVisible)
    window.removeEventListener('online', run)
    window.removeEventListener('offline', onOffline)
  }
}

/**
 * Picks up the pairing token from the Mac's QR link (`#pair=<token>`) or from the Home Screen
 * icon's start URL (`/?pair=<token>`). Returns true if one was found.
 *
 * iOS gives a Home Screen web app its own storage, separate from Safari's. So while this page is
 * still a Safari tab, the token stays in the address and the manifest is swapped for one whose
 * `start_url` carries it (served by the Mac), and the installed icon opens already paired.
 */
export async function consumePairingFragment(): Promise<boolean> {
  const fromHash = /^#pair=([^&]+)/.exec(location.hash)?.[1]
  const fromQuery = new URLSearchParams(location.search).get('pair')
  const raw = fromHash ?? fromQuery
  if (!raw) return false
  const token = decodeURIComponent(raw)
  await setMeta('pairToken', token)
  if (isStandalone()) {
    const query = new URLSearchParams(location.search)
    query.delete('pair')
    const rest = query.toString()
    history.replaceState(null, '', location.pathname + (rest ? `?${rest}` : ''))
  } else {
    // Keep the token in the address itself (a fragment may be dropped when the page is added to
    // the Home Screen), and in the manifest's start URL.
    if (fromHash) history.replaceState(null, '', `/?pair=${encodeURIComponent(token)}`)
    pointManifestAt(token)
  }
  return true
}

/** "k7qm 3xtp" → "K7QM3XTP": codes are shown as XXXX-XXXX but typed any old way. */
export function normalizePairingCode(code: string): string {
  return code.toUpperCase().replace(/[^A-Z0-9]/g, '')
}

/**
 * Pairs with the short code the Mac shows next to the QR code — the way to pair an app that's
 * already on the Home Screen, since scanning a QR code always opens Safari instead.
 * Returns an error message, or null once paired.
 */
export async function pairWithCode(code: string): Promise<string | null> {
  const normalized = normalizePairingCode(code)
  if (normalized.length < 8) return 'Enter the 8-character code shown on your Mac.'
  let res: Response
  try {
    res = await fetchWithTimeout(
      '/api/pair',
      {
        method: 'POST',
        cache: 'no-store',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code: normalized, deviceId: await deviceId(), deviceName: (await allMeta()).deviceName ?? '' }),
      },
      10_000,
    )
  } catch {
    return 'Can’t reach your Mac. Make sure you’re on your home Wi-Fi and Upkeep is running on the Mac.'
  }
  if (res.status === 404 || res.status === 403) return 'That code didn’t work. Check it, or make a new one on your Mac (Settings › Phones › Pair a Phone…).'
  if (res.status === 429) return 'Too many tries. Make a new code on your Mac.'
  if (!res.ok) return `Your Mac couldn’t pair this device (${res.status}).`
  try {
    const body = (await res.json()) as { token?: unknown }
    if (typeof body.token !== 'string' || !body.token) return 'Your Mac sent an unexpected answer.'
    await setMeta('pairToken', body.token)
  } catch {
    return 'Your Mac sent an unexpected answer.'
  }
  void LanTransport.sync()
  return null
}

/** Points the page at a manifest whose start URL pairs the installed app. */
export function pointManifestAt(token: string): void {
  let link = document.querySelector<HTMLLinkElement>('link[rel="manifest"]')
  if (!link) {
    link = document.createElement('link')
    link.rel = 'manifest'
    document.head.appendChild(link)
  }
  link.href = `/manifest.webmanifest?pair=${encodeURIComponent(token)}`
}

// MARK: Files

/** What an export produced, so the app can say what the file is and where it belongs. */
export interface ExportResult {
  how: 'shared' | 'downloaded' | 'cancelled'
  /** `<deviceId>.json` — the same name every time, so it replaces the old file. */
  name: string
  records: number
  at: number
}

export interface ImportResult {
  files: { name: string; ok: boolean; error?: string; device?: string }[]
  summary?: MergeSummary
}

export const FilesTransport = {
  /** Reads, validates and merges the chosen snapshot files in one go. Bad files are skipped. */
  async importFiles(files: Iterable<File>): Promise<ImportResult> {
    const results: ImportResult['files'] = []
    const snapshots: Snapshot[] = []
    const mine = (await allMeta()).householdId
    for (const file of files) {
      try {
        const snapshot = decodeSnapshot(await file.text())
        // Another household's file would bring its people and items in as second copies.
        if (mine && snapshot.device.householdId && snapshot.device.householdId !== mine) {
          results.push({ name: file.name, ok: false, error: 'From another household — skipped' })
          continue
        }
        snapshots.push(snapshot)
        results.push({ name: file.name, ok: true, device: snapshot.device.name || snapshot.device.id })
      } catch (error) {
        results.push({ name: file.name, ok: false, error: error instanceof SnapshotError ? error.message : 'Couldn’t read this file.' })
      }
    }
    if (!snapshots.length) return { files: results }
    if (!mine) {
      const household = snapshots.find((s) => s.device.householdId)?.device.householdId
      if (household) await setMeta('householdId', household)
    }
    const summary = await applyMerge(snapshots)
    await markSynced(localChangeCount(), 'lastImport')
    return { files: results, summary }
  },

  /** `<deviceId>.json` through the share sheet (Save to Files), or a download where sharing files isn't supported. */
  async exportOwn(): Promise<ExportResult> {
    const changesAtStart = localChangeCount()
    const snapshot = await ownSnapshot()
    const name = `${snapshot.device.id}.json`
    const text = encodeSnapshot(snapshot)
    const file = new File([text], name, { type: 'application/json' })
    const details = { name, records: snapshot.records.length, at: Date.now() }
    const nav = navigator as Navigator & { canShare?: (data: ShareData) => boolean }
    if (typeof nav.share === 'function' && nav.canShare?.({ files: [file] })) {
      try {
        await nav.share({ files: [file] })
        await markSynced(changesAtStart, 'lastExport')
        return { how: 'shared', ...details }
      } catch (error) {
        if (error instanceof DOMException && error.name === 'AbortError') return { how: 'cancelled', ...details }
        // Share failed for another reason: fall back to a download.
      }
    }
    const url = URL.createObjectURL(file)
    const a = document.createElement('a')
    a.href = url
    a.download = name
    document.body.appendChild(a)
    a.click()
    a.remove()
    setTimeout(() => URL.revokeObjectURL(url), 10_000)
    await markSynced(changesAtStart, 'lastExport')
    return { how: 'downloaded', ...details }
  },
}

/** Local changes waiting for 3+ days without a sync or export. */
export const STALE_AFTER_MS = 3 * 86_400_000

export function isStale(firstUnsyncedChange: number | undefined, now = Date.now()): boolean {
  return !!firstUnsyncedChange && now - firstUnsyncedChange >= STALE_AFTER_MS
}

