// The offline copy of the app: the service worker and the files it answers every launch with, so
// Upkeep opens when the Mac can't be reached. A Home Screen app without one has nothing to open
// away from home, and iOS shows a blank white page — so the app says so while it still can.
import { LanTransport } from './sync'

export type OfflineCopy =
  /** Just launched; the worker may not have registered yet. */
  | 'checking'
  /** A worker is fetching the app's files for the first time. */
  | 'installing'
  | 'ready'
  /** No worker, or iOS emptied its files: the next launch away from home would be blank. */
  | 'missing'
  /** Development builds and browsers without service workers. */
  | 'unsupported'

/** Registration waits for the page's load event, so a missing worker this soon isn't news yet. */
const REGISTER_GRACE_MS = 5000
const POLL_MS = 2000
/** A worker that hasn't answered by now is from before it could. */
const STATUS_TIMEOUT_MS = 3000
/** Long enough for the whole app over home Wi-Fi. */
const REFILL_TIMEOUT_MS = 60_000
/** Taking over from the active worker takes a moment, not a download. */
const ACTIVATE_TIMEOUT_MS = 10_000

let state: OfflineCopy = 'checking'
const listeners = new Set<() => void>()
let timer: ReturnType<typeof setTimeout> | undefined
let started = false
let autoRepaired = false

function set(next: OfflineCopy) {
  if (next === state) return
  state = next
  for (const l of listeners) l()
}

/** Sends `type` to a worker and waits for its answer on a port; undefined if none came. */
function ask<T>(worker: ServiceWorker, type: string, timeoutMs: number): Promise<T | undefined> {
  return new Promise((resolve) => {
    const channel = new MessageChannel()
    const timeout = setTimeout(() => resolve(undefined), timeoutMs)
    channel.port1.onmessage = (event) => {
      clearTimeout(timeout)
      resolve(event.data as T)
    }
    worker.postMessage({ type }, [channel.port2])
  })
}

/** Whether the precache holds the app shell, whatever revision its key carries. */
async function hasShell(): Promise<boolean> {
  for (const name of await caches.keys()) {
    if (!name.startsWith('workbox-precache')) continue
    const keys = await (await caches.open(name)).keys()
    if (keys.some((r) => new URL(r.url).pathname === '/index.html')) return true
  }
  return false
}

async function read(): Promise<OfflineCopy> {
  if (import.meta.env.DEV || !('serviceWorker' in navigator) || typeof caches === 'undefined') return 'unsupported'
  const reg = await navigator.serviceWorker.getRegistration('/')
  if (!reg?.active) {
    if (reg?.installing || reg?.waiting) return 'installing'
    return performance.now() < REGISTER_GRACE_MS ? 'checking' : 'missing'
  }
  // Every launch away from home is answered by the active worker from its own files. A newer
  // version waiting behind it may have a whole set while the active one's are gone — which is
  // why counting any copy of the app shell said Ready over a blank launch.
  const status = await ask<{ complete?: boolean }>(reg.active, 'PRECACHE_STATUS', STATUS_TIMEOUT_MS)
  // A worker from before it could say: the shell is the best guess, unless an update waits
  // whose files could be the only ones there.
  const complete = status ? !!status.complete : !reg.waiting && (await hasShell())
  if (complete) return 'ready'
  return reg.installing ? 'installing' : 'missing'
}

/** Resolves once `worker` has taken over (or gone), or false after a while. */
function activated(worker: ServiceWorker): Promise<boolean> {
  return new Promise((resolve) => {
    const done = () => {
      if (worker.state === 'activated') resolve(true)
      else if (worker.state === 'redundant') resolve(false)
    }
    worker.addEventListener('statechange', done)
    setTimeout(() => resolve(false), ACTIVATE_TIMEOUT_MS)
    done()
  })
}

/**
 * Puts a broken offline copy right. An update waiting with its files already downloaded takes
 * over — no Mac needed, and iOS drops a waiting worker when the app is closed, so it'd never get
 * the chance otherwise. Failing that, the active worker downloads what it lacks from the Mac.
 * False when neither worked.
 */
async function repair(reg: ServiceWorkerRegistration): Promise<boolean> {
  if (reg.waiting) {
    const waiting = reg.waiting
    waiting.postMessage({ type: 'SKIP_WAITING' })
    return activated(waiting)
  }
  if (!reg.active) return false
  return !!(await ask<{ ok?: boolean }>(reg.active, 'REFILL_PRECACHE', REFILL_TIMEOUT_MS))?.ok
}

/** Reads the state now, and again shortly while it's still settling. */
export function refreshOfflineCopy(): void {
  clearTimeout(timer)
  void read()
    .catch((): OfflineCopy => 'missing')
    .then((next) => {
      set(next)
      if (next === 'checking' || next === 'installing') timer = setTimeout(refreshOfflineCopy, POLL_MS)
      if (next === 'missing') void autoRepair()
    })
}

/** Once a launch, quietly: this fixes it before anyone sees the banner. */
async function autoRepair() {
  if (autoRepaired) return
  autoRepaired = true
  const reg = await navigator.serviceWorker.getRegistration('/')
  if (reg && (await repair(reg))) refreshOfflineCopy()
}

/** Checks at every launch, whatever screen is up — the repair shouldn't wait for Up Next. */
export function startOfflineCopy(): void {
  if (started) return
  started = true
  refreshOfflineCopy()
  document.addEventListener('visibilitychange', () => document.visibilityState === 'visible' && refreshOfflineCopy())
  navigator.serviceWorker?.addEventListener('controllerchange', refreshOfflineCopy)
  void navigator.serviceWorker?.getRegistration('/').then((reg) => reg?.addEventListener('updatefound', refreshOfflineCopy))
}

export function getOfflineCopy(): OfflineCopy {
  return state
}

export function subscribeOfflineCopy(listener: () => void): () => void {
  startOfflineCopy()
  listeners.add(listener)
  return () => listeners.delete(listener)
}

/**
 * Downloads the offline copy again from the Mac (see `repair`); with no worker at all, a reload
 * from the Mac registers one. Only where the Mac answers: away from home there's nothing to
 * download from.
 */
export async function reinstallOfflineCopy(): Promise<'ready' | 'downloading' | 'reloading' | 'away' | 'failed'> {
  if (!(await LanTransport.ping())) return 'away'
  const reg = await navigator.serviceWorker.getRegistration('/')
  // A newer version on the Mac installs with a full precache of its own; the state follows it.
  await reg?.update().catch(() => undefined)
  if (reg?.installing) {
    refreshOfflineCopy()
    return 'downloading'
  }
  if (!reg?.active) {
    location.reload()
    return 'reloading'
  }
  const ok = await repair(reg)
  refreshOfflineCopy()
  return ok ? 'ready' : 'failed'
}
