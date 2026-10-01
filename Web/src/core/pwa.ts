// Service worker registration handle for the update banner. The build stamp itself lives in
// `build.ts`, which the service worker can import too.

export { APP_VERSION, BUILD_DATE, BUILD_HASH, BUILD_STAMP } from './build'

let registration: ServiceWorkerRegistration | undefined
let applyUpdate: ((reload?: boolean) => Promise<void>) | undefined

export function setRegistration(reg: ServiceWorkerRegistration | undefined, update?: (reload?: boolean) => Promise<void>): void {
  registration = reg
  if (update) applyUpdate = update
}

export function setUpdater(update: (reload?: boolean) => Promise<void>): void {
  applyUpdate = update
}

/** Asks the service worker to look for a new version. Returns false when there's no worker. */
export async function checkForUpdate(): Promise<boolean> {
  if (!registration) return false
  try {
    await registration.update()
    return true
  } catch {
    return false
  }
}

const RELOAD_KEY = 'upkeep.forcedUpdateAt'

/**
 * The Mac requires a newer PWA (409): fetch the new worker, activate it and reload.
 * Guarded so a mismatch that an update can't fix doesn't reload in a loop.
 */
export async function forceUpdate(): Promise<void> {
  try {
    const last = Number(sessionStorage.getItem(RELOAD_KEY) ?? 0)
    if (Date.now() - last < 60_000) return
    sessionStorage.setItem(RELOAD_KEY, String(Date.now()))
  } catch {
    // Storage unavailable: still try once.
  }
  await checkForUpdate()
  const waiting = registration?.waiting
  if (waiting && applyUpdate) {
    await applyUpdate(true)
    return
  }
  if (waiting) {
    navigator.serviceWorker?.addEventListener('controllerchange', () => location.reload(), { once: true })
    waiting.postMessage({ type: 'SKIP_WAITING' })
    return
  }
  location.reload()
}
