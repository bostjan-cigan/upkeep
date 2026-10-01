import { useRef, useState } from 'react'
import { setMeta } from '../core/db'
import { type Person } from '../core/people'
import { setMyPerson } from '../core/push'
import { FilesTransport, LanTransport } from '../core/sync'
import { useLanState } from './hooks'
import { PairCodeEntry } from './PairCode'
import { PersonEditorSheet } from './HouseholdSettings'
import { PersonPicker } from './Settings'

function guessDeviceName(): string {
  const ua = navigator.userAgent
  if (/iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return 'iPad'
  if (/iPhone/.test(ua)) return 'iPhone'
  if (/Android/.test(ua)) return 'Android phone'
  return 'Browser'
}

/** First run: name this device, then say who you are — someone synced from the Mac, or a new person. */
export function Onboarding({ people, paired, hasData }: { people: Person[]; paired: boolean; hasData: boolean }) {
  const [step, setStep] = useState<'name' | 'who'>('name')
  const [addingMe, setAddingMe] = useState(false)
  const [name, setName] = useState(guessDeviceName)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState<string | null>(null)
  const fileInput = useRef<HTMLInputElement>(null)
  const lan = useLanState()

  const finish = async (personUid?: string) => {
    if (personUid) await setMyPerson(personUid)
    await setMeta('onboarded', true)
  }

  if (step === 'name') {
    return (
      <div className="onboarding">
        <img className="app-icon" src="/icons/icon-180.png" alt="" />
        <h1>Welcome to Upkeep</h1>
        <p className="lede">Your household’s routines, with a big friendly Done button.</p>
        <div className="section">
          <div className="section-header">
            <h2 className="section-title">This device’s name</h2>
          </div>
          <div className="card">
            <label className="row">
              <input className="field" value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Ana’s iPhone" autoFocus enterKeyHint="next" />
            </label>
          </div>
          <p className="section-footer">Shown on your Mac so you can tell devices apart.</p>
        </div>
        <div className="grow" />
        <div className="actions">
          <button
            className="button primary wide"
            disabled={!name.trim()}
            onClick={() => {
              void setMeta('deviceName', name.trim())
              setStep('who')
            }}
          >
            Continue
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="onboarding">
      <h1>Who are you?</h1>
      <p className="lede">Upkeep shows your tasks first and sends your reminders.</p>
      {people.length > 0 || hasData ? (
        <>
          {people.length > 0 && <PersonPicker people={people} selected="" onPick={(uid) => void finish(uid)} />}
          <p className="section-footer" style={{ padding: '14px 4px 8px' }}>{people.length ? 'Not listed?' : 'Nobody’s in this household yet.'}</p>
          <button className="button tinted wide" onClick={() => setAddingMe(true)}>
            Add Me
          </button>
        </>
      ) : (
        <div className="card" style={{ padding: 16 }}>
          <p style={{ margin: 0, fontWeight: 600 }}>Sync with your Mac first</p>
          <p className="muted" style={{ margin: '6px 0 0', fontSize: 15 }}>
            {paired
              ? lan.status === 'syncing'
                ? 'Syncing…'
                : 'Your household will appear here after syncing. Make sure you’re on your home Wi-Fi.'
              : 'Enter the code your Mac shows (Upkeep › Settings › Phones › Pair a Phone…). Or import your household’s files.'}
          </p>
          {message && <p className="muted" style={{ margin: '8px 0 0', fontSize: 15 }}>{message}</p>}
          {paired && lan.message && <p className="muted" style={{ margin: '8px 0 0', fontSize: 15 }}>{lan.message}</p>}
          {(!paired || lan.status === 'unauthorized') && (
            <div className="card nested">
              <PairCodeEntry />
            </div>
          )}
        </div>
      )}
      <div className="grow" />
      <div className="actions">
        {people.length === 0 && paired && (
          <button className="button tinted wide" disabled={lan.status === 'syncing'} onClick={() => void LanTransport.sync()}>
            Sync Now
          </button>
        )}
        {people.length === 0 && (
          <button className="button tinted wide" disabled={busy} onClick={() => fileInput.current?.click()}>
            Import from Files…
          </button>
        )}
        <button className="button plain wide" onClick={() => void finish()}>
          Skip for Now
        </button>
      </div>
      {addingMe && <PersonEditorSheet onClose={() => setAddingMe(false)} onCreated={(uid) => void finish(uid)} />}
      <input
        ref={fileInput}
        type="file"
        multiple
        accept=".json,application/json"
        className="sr-only"
        onChange={async (e) => {
          const files = e.currentTarget.files
          if (!files?.length) return
          setBusy(true)
          const result = await FilesTransport.importFiles([...files])
          setBusy(false)
          const bad = result.files.filter((f) => !f.ok)
          setMessage(bad.length ? bad.map((f) => `${f.name}: ${f.error}`).join('\n') : null)
        }}
      />
    </div>
  )
}
