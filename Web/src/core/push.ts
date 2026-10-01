// Web Push reminders sent by the Mac (Docs/Sync.md › Phone notifications). There's no server of
// our own: the Mac encrypts and posts pushes straight to the subscription endpoint.
import { allMeta, deviceId, getMeta, setMeta } from './db'

/** Installed to the Home Screen: the only place iOS allows Web Push. */
export function isStandalone(): boolean {
  const nav = navigator as Navigator & { standalone?: boolean }
  return nav.standalone === true || (typeof matchMedia === 'function' && matchMedia('(display-mode: standalone)').matches)
}

export function pushSupported(): boolean {
  return typeof window !== 'undefined' && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window
}

export function permission(): NotificationPermission | 'unsupported' {
  return typeof Notification === 'undefined' ? 'unsupported' : Notification.permission
}

/** base64url (no padding) → bytes, for `applicationServerKey`. */
export function base64UrlToBytes(value: string): Uint8Array<ArrayBuffer> {
  const base64 = value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (value.length % 4)) % 4)
  const raw = atob(base64)
  const bytes = new Uint8Array(new ArrayBuffer(raw.length))
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i)
  return bytes
}

async function registration(timeoutMs = 4000): Promise<ServiceWorkerRegistration | null> {
  if (!('serviceWorker' in navigator)) return null
  return Promise.race([
    navigator.serviceWorker.ready,
    new Promise<null>((resolve) => setTimeout(() => resolve(null), timeoutMs)),
  ])
}

async function api(path: string, token: string, init: RequestInit = {}): Promise<Response> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 10_000)
  try {
    return await fetch(path, {
      ...init,
      cache: 'no-store',
      signal: controller.signal,
      headers: { ...(init.body ? { 'Content-Type': 'application/json' } : {}), Authorization: `Bearer ${token}` },
    })
  } finally {
    clearTimeout(timer)
  }
}

export type PushResult = { ok: true } | { ok: false; message: string }

const fail = (message: string): PushResult => ({ ok: false, message })

async function postSubscription(token: string, sub: PushSubscription): Promise<Response> {
  const meta = await allMeta()
  return api('/api/push/subscribe', token, {
    method: 'POST',
    body: JSON.stringify({ deviceId: await deviceId(), personUid: meta.myPersonUid ?? '', subscription: sub.toJSON() }),
  })
}

/** Permission → Mac's VAPID key → subscribe → register the subscription with the Mac. */
export async function enablePush(): Promise<PushResult> {
  if (!pushSupported()) return fail('This browser can’t receive notifications from Upkeep.')
  if (!isStandalone()) return fail('Add Upkeep to your Home Screen first, then open it from there.')
  const token = await getMeta('pairToken')
  if (!token) return fail('Pair this device with your Mac first.')

  const granted = await Notification.requestPermission()
  if (granted !== 'granted') return fail('Notifications are off for Upkeep. You can turn them on in Settings › Notifications › Upkeep.')

  const reg = await registration()
  if (!reg) return fail('Upkeep isn’t fully installed yet. Reopen it and try again.')

  let keyRes: Response
  try {
    keyRes = await api('/api/push/key', token)
  } catch {
    return fail('Can’t reach your Mac. Make sure you’re at home on the same Wi-Fi.')
  }
  if (keyRes.status === 401) return fail('This device isn’t paired any more. Scan the pairing code on your Mac again.')
  if (!keyRes.ok) return fail('Your Mac can’t send notifications yet. Update Upkeep on the Mac.')
  const { publicKey } = (await keyRes.json()) as { publicKey?: string }
  if (!publicKey) return fail('Your Mac didn’t send a notification key.')

  let sub: PushSubscription
  try {
    const key = base64UrlToBytes(publicKey)
    const existing = await reg.pushManager.getSubscription()
    // A subscription made for another key (e.g. a different Mac) has to be replaced.
    if (existing && !sameKey(existing, key)) await existing.unsubscribe()
    sub = (existing && sameKey(existing, key) ? existing : null) ?? (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key }))
  } catch {
    return fail('Couldn’t turn on notifications on this device.')
  }

  try {
    const res = await postSubscription(token, sub)
    if (!res.ok) return fail('Your Mac didn’t accept the subscription. Try again.')
  } catch {
    return fail('Can’t reach your Mac. Make sure you’re at home on the same Wi-Fi.')
  }
  await setMeta('pushEnabled', true)
  return { ok: true }
}

function sameKey(sub: PushSubscription, key: Uint8Array): boolean {
  const current = sub.options.applicationServerKey
  if (!current) return false
  const a = new Uint8Array(current)
  return a.length === key.length && a.every((b, i) => b === key[i])
}

/** Unsubscribes here and tells the Mac to forget this device. */
export async function disablePush(): Promise<PushResult> {
  const reg = await registration()
  try {
    await (await reg?.pushManager.getSubscription())?.unsubscribe()
  } catch {
    // Already gone.
  }
  await setMeta('pushEnabled', false)
  const token = await getMeta('pairToken')
  if (token) {
    try {
      await api('/api/push/unsubscribe', token, { method: 'POST', body: JSON.stringify({ deviceId: await deviceId() }) })
    } catch {
      return fail('Turned off here. Your Mac will stop once it can reach this device’s subscription again.')
    }
  }
  return { ok: true }
}

/**
 * Re-sends the current subscription (after a sync, or when "who am I" changes) so the Mac targets
 * the right person. Silent: failures just wait for the next sync.
 */
export async function refreshPushSubscription(): Promise<void> {
  if (!(await getMeta('pushEnabled'))) return
  const token = await getMeta('pairToken')
  if (!token || !pushSupported()) return
  try {
    const reg = await registration(1500)
    let sub = await reg?.pushManager.getSubscription()
    if (!reg || !sub) {
      // The system dropped the subscription (permission revoked, reinstall…).
      if (permission() !== 'granted') await setMeta('pushEnabled', false)
      return
    }
    // The household signs with one key. A phone subscribed with another — its Mac's own, from
    // before the household shared one — switches quietly, since permission is already granted.
    const keyRes = await api('/api/push/key', token)
    const publicKey = keyRes.ok ? ((await keyRes.json()) as { publicKey?: string }).publicKey : undefined
    if (publicKey) {
      const key = base64UrlToBytes(publicKey)
      if (!sameKey(sub, key)) {
        await sub.unsubscribe()
        sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key })
      }
    }
    await postSubscription(token, sub)
  } catch {
    // Offline or not at home.
  }
}

/**
 * Which person this device belongs to (people themselves are edited in peopleEditing.ts).
 * Lives here, not in `people.ts`, so that module stays free of the DOM — the service
 * worker imports it to recompute the badge.
 */
export async function setMyPerson(uid: string): Promise<void> {
  await setMeta('myPersonUid', uid)
  // The Mac sends reminders for the person a subscription belongs to.
  void refreshPushSubscription()
}
