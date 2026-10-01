import { useState } from 'react'
import { reinstallOfflineCopy, type OfflineCopy } from '../core/offline'
import { isStandalone } from '../core/push'
import { useApp, useOfflineCopy } from './hooks'
import { Warning } from './icons'
import { Row } from './ui'

const LABELS: Record<OfflineCopy, string> = {
  checking: 'Checking…',
  installing: 'Downloading…',
  ready: 'Ready',
  missing: 'Missing',
  unsupported: import.meta.env.DEV ? 'Not in development' : 'Not available',
}

/** Reinstalls, or says why it can't from here. */
function useReinstall(): [busy: boolean, run: () => void] {
  const { toast } = useApp()
  const [busy, setBusy] = useState(false)
  const run = () => {
    if (busy) return
    setBusy(true)
    void reinstallOfflineCopy()
      .then((result) => {
        if (result === 'away') toast('Can’t reach your Mac. Reinstall it at home, on your home Wi-Fi, with Upkeep running on the Mac.')
        if (result === 'failed') toast('Couldn’t download the offline copy from your Mac. Try again in a moment.')
      })
      .catch(() => toast('Couldn’t reinstall the offline copy. Try again in a moment.'))
      .finally(() => setBusy(false))
  }
  return [busy, run]
}

/** Settings › About: whether Upkeep opens away from home, and the way to fix it when it wouldn't. */
export function OfflineCopyRows() {
  const copy = useOfflineCopy()
  const [busy, reinstall] = useReinstall()
  return (
    <>
      <Row
        title="Offline Copy"
        subtitle={copy === 'missing' ? 'Upkeep won’t open away from home until it’s reinstalled. Do it here at home.' : undefined}
        value={LABELS[copy]}
      />
      {copy === 'missing' && <Row className="action" title={busy ? 'Reinstalling…' : 'Reinstall Offline Copy'} onClick={busy ? undefined : reinstall} />}
    </>
  )
}

/**
 * Up Next, on the Home Screen app only: its offline copy is gone, so the next launch away from
 * home would be a blank screen. A Safari tab reloads from the Mac anyway and gets no banner.
 */
export function OfflineCopyBanner() {
  const copy = useOfflineCopy()
  const [busy, reinstall] = useReinstall()
  if (copy !== 'missing' || !isStandalone()) return null
  return (
    <div className="banner warn" role="status">
      <Warning style={{ color: 'var(--orange)' }} />
      <span className="grow">Upkeep won’t open away from home: its offline copy is missing. Fix it while you’re at home.</span>
      <button className="button small tinted" disabled={busy} onClick={reinstall}>
        {busy ? 'Fixing…' : 'Fix'}
      </button>
    </div>
  )
}
