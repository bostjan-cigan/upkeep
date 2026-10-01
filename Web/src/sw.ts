/// <reference lib="webworker" />
// Service worker: offline precache + navigation fallback, prompt-style updates, Web Push
// reminders sent by the Mac (Docs/Sync.md › Phone notifications), and one sync attempt per
// reminder so a phone at home keeps up without being opened.
//
// This file is typechecked on its own (tsconfig.sw.json) with the WebWorker lib and no DOM —
// which is what stops a `document` or `window` import sneaking into the graph through some
// module it pulls in. Don't add "DOM" to that lib list to make an import compile; move the
// DOM-free half of that module out instead, the way `lanSync.ts` was split from `sync.ts`.
import { cleanupOutdatedCaches, PrecacheController, PrecacheRoute } from 'workbox-precaching'
import { NavigationRoute, registerRoute } from 'workbox-routing'
import { db, getMeta } from './core/db'
import { lanSyncOnce } from './core/lanSync'
import { attentionCount, buildHousehold } from './modules/maintenance'

declare const self: ServiceWorkerGlobalScope & { __WB_MANIFEST: (string | { url: string; revision: string | null })[] }

// Our own controller rather than `precacheAndRoute`, so `refillPrecache` can reach its list.
// Same default cache name, so a phone updating from an older worker keeps what it has.
const precache = new PrecacheController()
precache.precache(self.__WB_MANIFEST)
registerRoute(new PrecacheRoute(precache))
cleanupOutdatedCaches()
// Any navigation (except the Mac's API) gets the cached app shell, so the app opens offline.
registerRoute(new NavigationRoute(precache.createHandlerBoundToURL('/index.html'), { denylist: [/^\/api\//] }))

/**
 * Downloads whatever is missing from the precache. Workbox only fills it while this worker
 * installs, so once iOS has emptied it the active worker would serve a blank page forever:
 * the same `sw.js` never installs again, and unregistering from a page it controls doesn't
 * reliably give a fresh install either. Throws when the Mac can't be reached.
 */
async function refillPrecache(): Promise<void> {
  const cache = await caches.open(precache.strategy.cacheName)
  await Promise.all(
    [...precache.getURLsToCacheKeys().values()].map(async (key) => {
      if (await cache.match(key)) return
      let response = await fetch(key, { cache: 'reload', credentials: 'same-origin' })
      if (!response.ok) throw new Error(`${response.status} ${key}`)
      // Safari won't answer a navigation with a redirected response; Workbox copies them too.
      if (response.redirected) response = new Response(await response.blob(), response)
      await cache.put(key, response)
    }),
  )
}

/**
 * Whether every file this worker answers launches with is in the precache under its own
 * revision. Another version's files don't count: this worker looks for its own, and on a miss
 * goes to the network — a blank page away from home.
 */
async function precacheComplete(): Promise<boolean> {
  const cache = await caches.open(precache.strategy.cacheName)
  const hits = await Promise.all([...precache.getURLsToCacheKeys().values()].map((key) => cache.match(key)))
  return hits.every(Boolean)
}

self.addEventListener('message', (event) => {
  const type = (event.data as { type?: string } | null)?.type
  // The page asks for this when the user taps "Reload" on the update banner, and when the
  // active worker's copy is broken while this one waits with a whole one (core/offline.ts).
  if (type === 'SKIP_WAITING') void self.skipWaiting()
  // Settings › Offline Copy and the Up Next banner: both answer on the port they were handed.
  if (type === 'PRECACHE_STATUS') {
    const port = event.ports[0]
    event.waitUntil(
      precacheComplete().then(
        (complete) => port?.postMessage({ complete }),
        () => port?.postMessage({ complete: false }),
      ),
    )
  }
  if (type === 'REFILL_PRECACHE') {
    const port = event.ports[0]
    event.waitUntil(
      refillPrecache().then(
        () => port?.postMessage({ ok: true }),
        () => port?.postMessage({ ok: false }),
      ),
    )
  }
})

interface PushPayload {
  title?: string
  body?: string
  tag?: string
  url?: string
  badge?: unknown
}

type BadgeNavigator = WorkerNavigator & { setAppBadge?: (n?: number) => Promise<void>; clearAppBadge?: () => Promise<void> }

function applyBadge(count: number): Promise<unknown> | undefined {
  const nav = self.navigator as BadgeNavigator
  try {
    if (count > 0 && nav.setAppBadge) return nav.setAppBadge(count).catch(() => undefined)
    if (count <= 0 && nav.clearAppBadge) return nav.clearAppBadge().catch(() => undefined)
  } catch {
    // Badging isn't supported here.
  }
  return undefined
}

/**
 * One sync attempt while the phone is awake for a reminder. At home it lands; away from home
 * the fetch fails and nothing is written. The Mac's badge count came from before this sync,
 * so once something has actually changed — tasks ticked off on this phone while it was
 * offline — recompute it here. A failed or empty sync leaves the Mac's number alone.
 */
async function syncAfterPush(): Promise<void> {
  const outcome = await lanSyncOnce(8000)
  if (outcome.kind !== 'ok') return
  const { added, updated, removed } = outcome.summary
  if (!added && !updated && !removed) return
  const now = Date.now()
  const household = buildHousehold(await db.records.toArray(), now)
  const myPersonUid = (await getMeta('myPersonUid')) ?? ''
  await applyBadge(attentionCount(household, myPersonUid, now))
}

self.addEventListener('push', (event) => {
  let payload: PushPayload = {}
  try {
    payload = (event.data?.json() ?? {}) as PushPayload
  } catch {
    payload = { body: event.data?.text() }
  }
  const title = payload.title || 'Upkeep'
  const tasks: Promise<unknown>[] = [
    self.registration.showNotification(title, {
      body: payload.body ?? '',
      tag: payload.tag || 'upkeep-nag',
      data: { url: payload.url || '/' },
      // iOS ignores both and draws the installed web app's own icon (the apple-touch-icon it
      // took when the app was added to the Home Screen). Everywhere else these are used: the
      // app icon beside the text, and the flat white glyph as the small monochrome mark.
      icon: '/icons/icon-192.png',
      badge: '/icons/badge-96.png',
    }),
  ]
  if (typeof payload.badge === 'number' && Number.isFinite(payload.badge)) {
    const badging = applyBadge(payload.badge)
    if (badging) tasks.push(badging)
  }
  // Queued after the notification, never in front of it: iOS requires every push to show one.
  tasks.push(syncAfterPush().catch(() => undefined))
  event.waitUntil(Promise.all(tasks))
})

self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  const raw = (event.notification.data as { url?: string } | null)?.url || '/'
  const target = new URL(raw, self.location.origin)
  // Only ever open our own origin.
  const url = target.origin === self.location.origin ? target.href : self.location.origin + '/'
  event.waitUntil(
    (async () => {
      const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
      for (const client of windows) {
        if (new URL(client.url).origin === self.location.origin) {
          await client.focus()
          if (client.url !== url && 'navigate' in client) await client.navigate(url).catch(() => undefined)
          return
        }
      }
      await self.clients.openWindow(url)
    })(),
  )
})
