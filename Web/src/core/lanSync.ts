// One sync round with the Mac, with no DOM anywhere in it: the app calls it through
// `LanTransport.sync()`, and the service worker calls it directly when a reminder arrives
// (see sw.ts). Keep this file, and everything it imports, free of `window`/`document`.
import { BUILD_STAMP } from './build'
import { allMeta, applyMerge, deviceId, getMeta, localSet, setMeta } from './db'
import type { MergeSummary } from './merge'
import { buildSnapshot, decodeSnapshot, encodeSnapshot, SnapshotError, type Snapshot } from './snapshot'

export type LanOutcome =
  | { kind: 'ok'; summary: MergeSummary; macName: string }
  | { kind: 'notPaired' }
  | { kind: 'unreachable' }
  | { kind: 'unauthorized' }
  | { kind: 'updateRequired' }
  | { kind: 'macNeedsUpdate' }
  /** This device still holds another household's copy; the Mac merged nothing. */
  | { kind: 'otherHousehold'; macName: string }
  | { kind: 'error'; message: string }

/** This device's snapshot of the whole replica. */
export async function ownSnapshot(now = Date.now()): Promise<Snapshot> {
  const id = await deviceId()
  const meta = await allMeta()
  const set = await localSet()
  return buildSnapshot(
    {
      id,
      name: meta.deviceName ?? '',
      platform: 'web',
      personUid: meta.myPersonUid ?? '',
      build: BUILD_STAMP,
      ...(meta.householdId ? { householdId: meta.householdId } : {}),
    },
    set.records,
    set.tombstones,
    { now },
  )
}

/** "standalone" for the Home Screen app, so the Mac's pairing wizard can tell it from Safari. */
function displayMode(): 'standalone' | 'browser' {
  // No DOM types here (the service worker shares this file): reach the window bits loosely.
  const scope = globalThis as { navigator?: { standalone?: boolean }; matchMedia?: (query: string) => { matches: boolean } }
  const standalone = scope.navigator?.standalone === true || scope.matchMedia?.('(display-mode: standalone)').matches === true
  return standalone ? 'standalone' : 'browser'
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

/**
 * One round trip: POST our snapshot to the Mac and merge its merged state back.
 * Never throws. Away from home the fetch simply fails and nothing is written.
 */
export async function lanSyncOnce(timeoutMs = 15_000): Promise<LanOutcome> {
  const token = (await allMeta()).pairToken
  if (!token) return { kind: 'notPaired' }

  // A local edit landing while the request is in flight bumps `maxSeen`, and must keep
  // `firstUnsyncedChange` set. The app's in-memory change counter can't be used here: the
  // service worker has its own module state, where it is always zero.
  const seenBefore = (await getMeta('maxSeen')) ?? 0

  let res: Response
  try {
    const body = encodeSnapshot(await ownSnapshot(), false)
    res = await fetchWithTimeout(
      '/api/sync',
      {
        method: 'POST',
        cache: 'no-store',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'X-Upkeep-Display': displayMode() },
        body,
      },
      timeoutMs,
    )
  } catch {
    return { kind: 'unreachable' }
  }

  try {
    switch (res.status) {
      case 200: {
        const snapshot = decodeSnapshot(await res.text())
        // Read before `applyMerge`, which writes `maxSeen` of its own.
        const seenAfter = (await getMeta('maxSeen')) ?? 0
        const summary = await applyMerge([snapshot])
        await setMeta('lastLanSync', Date.now())
        // From now on this copy says which household it belongs to.
        if (snapshot.device.householdId) await setMeta('householdId', snapshot.device.householdId)
        if (seenAfter === seenBefore) await setMeta('firstUnsyncedChange', 0)
        return { kind: 'ok', summary, macName: snapshot.device.name }
      }
      case 401:
        return { kind: 'unauthorized' }
      case 409: {
        const body = (await res.json().catch(() => ({}))) as { error?: string; household?: string }
        if (body.error === 'otherHousehold') return { kind: 'otherHousehold', macName: body.household ?? '' }
        return { kind: 'updateRequired' }
      }
      case 422:
        return { kind: 'macNeedsUpdate' }
      default:
        return { kind: 'error', message: `Your Mac answered with ${res.status}.` }
    }
  } catch (error) {
    return {
      kind: 'error',
      message: error instanceof SnapshotError ? error.message : 'The Mac sent something Upkeep couldn’t read.',
    }
  }
}
