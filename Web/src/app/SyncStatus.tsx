// The little live indicator in the navigation bar: whether this device is at home with the Mac,
// and every round trip it makes. It always says where it stands in words — a Wi-Fi glyph on its
// own would only say "Wi-Fi", which isn't what the household wants to know.
import { useEffect, useState, useSyncExternalStore, type SVGProps } from 'react'
import { syncStatus, type SyncStatus } from '../core/status'
import { getLanState, LanTransport, subscribeLan, type LanState } from '../core/sync'
import { useApp } from './hooks'
import { ArrowsSync, CheckCircleFill, House, Warning, Wifi, WifiSlash } from './icons'

/** How long "Synced" stays on screen after a round trip, before the pill settles down. */
const SYNCED_FOR_MS = 3500

function subscribeOnline(listener: () => void): () => void {
  window.addEventListener('online', listener)
  window.addEventListener('offline', listener)
  return () => {
    window.removeEventListener('online', listener)
    window.removeEventListener('offline', listener)
  }
}

/** `navigator.onLine`: false is a sure "no network"; true only means "worth a try". */
export function useOnline(): boolean {
  return useSyncExternalStore(
    subscribeOnline,
    () => navigator.onLine,
    () => true,
  )
}

/** True for a few seconds after a successful round trip, so the user sees their sync land. */
function useJustSynced(lan: LanState): boolean {
  const [until, setUntil] = useState(0)
  useEffect(() => {
    if (lan.status !== 'ok' || !lan.at) return
    setUntil(lan.at + SYNCED_FOR_MS)
    const timer = setTimeout(() => setUntil(0), SYNCED_FOR_MS)
    return () => clearTimeout(timer)
  }, [lan.status, lan.at])
  return until > Date.now()
}

/** The one reading of this device's link to the Mac, live. */
export function useSyncStatus(): SyncStatus {
  const { meta, now } = useApp()
  const lan = useSyncExternalStore(subscribeLan, getLanState)
  const online = useOnline()
  const justSynced = useJustSynced(lan)
  return syncStatus({
    lan,
    paired: !!meta.pairToken,
    online,
    lastLanSync: meta.lastLanSync,
    macName: meta.macName,
    pendingChanges: !!meta.firstUnsyncedChange,
    demo: !!meta.demoMode,
    justSynced,
    now,
  })
}

export function SyncGlyph({ status, ...rest }: { status: SyncStatus } & SVGProps<SVGSVGElement>) {
  switch (status.kind) {
    case 'pending':
    case 'syncing':
      return <ArrowsSync {...rest} />
    case 'synced':
      return <CheckCircleFill {...rest} />
    case 'offline':
    case 'away':
      return <WifiSlash {...rest} />
    case 'problem':
    case 'notPaired':
      return <Warning {...rest} />
    case 'demo':
      return <House {...rest} />
    default:
      return <Wifi {...rest} />
  }
}

/**
 * Tapping it does the obvious thing: sync now, or take you to Settings when the sync needs you.
 * When a sync it started doesn't land, it says why — the pill alone can't.
 */
export function SyncPill({ onOpenSettings }: { onOpenSettings: () => void }) {
  const { meta, toast } = useApp()
  const status = useSyncStatus()

  const onTap = () => {
    if (meta.demoMode || !meta.pairToken || status.kind === 'problem') return onOpenSettings()
    void LanTransport.sync().then((state) => {
      if (state.status === 'ok' || state.status === 'syncing') return
      // A tap that didn't land deserves a sentence: the pill has room for two words.
      const after = syncStatus({ lan: state, paired: true, online: navigator.onLine, lastLanSync: meta.lastLanSync, macName: meta.macName, pendingChanges: !!meta.firstUnsyncedChange, now: Date.now() })
      toast(after.hint)
    })
  }

  return (
    <>
      <button
        className={`sync-pill ${status.tone}`}
        onClick={onTap}
        aria-label={status.detail}
        title={status.hint}
      >
        <span className="sync-glyph">
          <SyncGlyph status={status} />
          {status.waiting && <span className="sync-dot" />}
        </span>
        <span className="sync-label">{status.label}</span>
      </button>
      {/* VoiceOver hears every change of state without the pill itself being re-read. */}
      <span className="sr-only" role="status" aria-live="polite">
        {status.detail}
      </span>
    </>
  )
}
