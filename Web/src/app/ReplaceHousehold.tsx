// When the Mac turned this phone's copy away as another household's (its Mac was reset or
// replaced): say so, and offer to replace it. Nothing merges until then, so no duplicates.
import { useState } from 'react'
import { resetReplica } from '../core/db'
import { LanTransport } from '../core/sync'
import { ConfirmSheet } from './form'
import { useApp, useLanState } from './hooks'
import { Warning } from './icons'

export function ReplaceHouseholdBanner() {
  const lan = useLanState()
  const { meta, toast } = useApp()
  const [confirming, setConfirming] = useState(false)
  const [busy, setBusy] = useState(false)
  if (lan.status !== 'otherHousehold') return null
  const mac = meta.macName || 'your Mac'

  const replace = async () => {
    setBusy(true)
    await resetReplica()
    const state = await LanTransport.sync()
    setBusy(false)
    setConfirming(false)
    toast(state.status === 'ok' ? `Now showing ${mac}’s household` : 'Replaced. It syncs as soon as your Mac is reachable.')
  }

  return (
    <>
      <div className="banner warn">
        <Warning style={{ color: 'var(--orange)' }} />
        <span className="grow">{lan.message}</span>
        <button className="button small tinted" onClick={() => setConfirming(true)}>
          Replace
        </button>
      </div>
      {confirming && (
        <ConfirmSheet
          title="Replace This Phone’s Copy?"
          message={
            <>
              This phone’s items, tasks, history and people are removed from this phone only, and {mac}’s
              household comes in their place. Nothing on {mac} or any other device changes. You’ll pick who you
              are again, and turn reminders back on in Settings.
            </>
          }
          confirm="Replace with This Household"
          destructive
          busy={busy}
          onConfirm={() => void replace()}
          onClose={() => setConfirming(false)}
        />
      )}
    </>
  )
}
