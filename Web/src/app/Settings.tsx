import { PairCodeEntry } from './PairCode'
import { useLiveQuery } from 'dexie-react-hooks'
import { useRef, useState } from 'react'
import { calendarDaysBetween, formatDate, relativeTime } from '../core/dates'
import { db, setMeta } from '../core/db'
import { MAC, PUSH_SUBSCRIPTION, reminderSenders, remindersFooter } from '../core/macs'
import { type Person } from '../core/people'
import { setMyPerson } from '../core/push'
import { disablePush, enablePush, isStandalone, permission, pushSupported } from '../core/push'
import { BUILD_DATE, BUILD_HASH, APP_VERSION, checkForUpdate } from '../core/pwa'
import { FilesTransport, isStale, LanTransport, type ExportResult, type ImportResult } from '../core/sync'
import { ConfirmSheet } from './form'
import { PeopleSection, RemindersSection } from './HouseholdSettings'
import { OfflineCopyRows } from './OfflineCopy'
import { ReplaceHouseholdBanner } from './ReplaceHousehold'
import { useAppearance, useApp, useLanState, usePreference } from './hooks'
import { setAppearancePreference } from './appearanceStore'
import type { AppearancePreference } from './appearance'
import { SyncGlyph, useSyncStatus } from './SyncStatus'
import { Avatar, Row, Section, Segmented, Sheet } from './ui'
import { Bell, CheckCircleFill, Folder, House, Warning } from './icons'

const APPEARANCE_OPTIONS: { value: AppearancePreference; label: string }[] = [
  { value: 'auto', label: 'Automatic' },
  { value: 'glass', label: 'Glass' },
  { value: 'classic', label: 'Classic' },
]

function AppearanceSection() {
  const { pref, backdrop, reducedTransparency } = useAppearance()
  const footer = !backdrop
    ? 'This device can’t draw the frosted appearance, so Upkeep is showing the flat one.'
    : reducedTransparency
      ? 'Reduce Transparency is on in your device’s accessibility settings, so Upkeep is showing the flat appearance.'
      : 'Automatic uses the frosted appearance wherever the device can draw it.'
  return (
    <Section title="Appearance" footer={footer}>
      <div className="row">
        <Segmented label="Appearance" value={pref} onChange={setAppearancePreference} options={APPEARANCE_OPTIONS} />
      </div>
    </Section>
  )
}

function describeImport(result: ImportResult): string {
  const ok = result.files.filter((f) => f.ok).length
  if (!result.summary) return ok ? 'Nothing new.' : 'No household files could be read.'
  const { added, updated, removed } = result.summary
  if (!added && !updated && !removed) return `Merged ${ok === 1 ? '1 file' : `${ok} files`}. You were already up to date.`
  const parts = [added && `${added} new`, updated && `${updated} updated`, removed && `${removed} removed`].filter(Boolean)
  return `Merged ${ok === 1 ? '1 file' : `${ok} files`}: ${parts.join(', ')}.`
}

function describeReminders(p: Person): string {
  const r = p.reminders
  const hours = r.nagHours === 1 ? 'every hour' : `every ${r.nagHours} hours`
  const pad = (h: number) => `${String(h).padStart(2, '0')}:00`
  let text = `Reminders ${hours}, ${pad(r.activeStart)}–${pad(r.activeEnd)}`
  if (r.workEnabled) text += `, not during work (${pad(r.workStart)}–${pad(r.workEnd)})`
  return text + '.'
}

export function PersonPicker({ people, selected, onPick }: { people: Person[]; selected: string; onPick: (uid: string) => void }) {
  return (
    <div className="card">
      {people.map((p) => (
        <Row
          key={p.uid}
          inset={56}
          leading={<Avatar person={p} size={30} />}
          title={p.name || 'Unnamed'}
          trailing={p.uid === selected ? <CheckCircleFill width={22} height={22} style={{ color: 'var(--tint)' }} /> : undefined}
          onClick={() => onPick(p.uid)}
        />
      ))}
    </div>
  )
}

/** Taps on the version row that unlock the developer options — the usual seven. */
const UNLOCK_TAPS = 7

export function Settings() {
  const { household, meta, now, me, myUid, toast } = useApp()
  const status = useSyncStatus()
  const lan = useLanState()
  const fileInput = useRef<HTMLInputElement>(null)
  const [picking, setPicking] = useState(false)
  const [importResult, setImportResult] = useState<ImportResult | null>(null)
  const [pushBusy, setPushBusy] = useState(false)
  const [pushMessage, setPushMessage] = useState<string | null>(null)
  const [exportResult, setExportResult] = useState<ExportResult | null>(null)
  const [unlocked, setUnlocked] = usePreference<'0' | '1'>('devUnlocked', '0')
  const [taps, setTaps] = useState(0)
  const [confirming, setConfirming] = useState<'demo' | 'erase' | null>(null)
  const [working, setWorking] = useState(false)
  const paired = !!meta.pairToken
  const demo = !!meta.demoMode
  const people = household.people
  const stale = isStale(meta.firstUnsyncedChange, now)
  const macName = meta.macName || 'your Mac'
  // Which Macs send this phone its reminders, from the records the Macs share.
  const pushRecords = useLiveQuery(() => db.records.where('kind').anyOf([MAC, PUSH_SUBSCRIPTION]).toArray(), [])
  const senders = pushRecords && meta.deviceId ? reminderSenders(pushRecords, meta.deviceId) : null

  const onFiles = async (files: FileList | null) => {
    if (!files?.length) return
    const result = await FilesTransport.importFiles([...files])
    setImportResult(result)
    if (fileInput.current) fileInput.current.value = ''
  }

  const exportFile = async () => {
    const result = await FilesTransport.exportOwn()
    if (result.how !== 'cancelled') setExportResult(result)
  }

  const togglePush = async (on: boolean) => {
    setPushBusy(true)
    setPushMessage(null)
    const result = on ? await enablePush() : await disablePush()
    setPushBusy(false)
    if (!result.ok) setPushMessage(result.message)
  }

  /** Seven taps on the version row, the way every other app does it. */
  const tapVersion = () => {
    if (unlocked === '1') return
    const next = taps + 1
    setTaps(next)
    if (next >= UNLOCK_TAPS) {
      setUnlocked('1')
      toast('Developer options are on.')
    } else if (next >= UNLOCK_TAPS - 3) {
      toast(`${UNLOCK_TAPS - next} more ${UNLOCK_TAPS - next === 1 ? 'tap' : 'taps'}…`)
    }
  }

  const runDemo = async () => {
    setWorking(true)
    const { enterDemoMode } = await import('./demo')
    await enterDemoMode()
    location.reload()
  }

  const runErase = async () => {
    setWorking(true)
    const { eraseDevice } = await import('./demo')
    await eraseDevice()
    location.reload()
  }

  const pushOn = !!meta.pushEnabled && permission() === 'granted'
  let pushHint: string
  if (!isStandalone()) pushHint = 'Add Upkeep to your Home Screen first: tap Share, then Add to Home Screen, and open it from there.'
  else if (!pushSupported()) pushHint = 'This device can’t receive notifications from Upkeep. Update iOS to 16.4 or later.'
  else if (!paired) pushHint = 'Pair this device with your Mac first. Notifications are set up over your home Wi-Fi.'
  else pushHint = `${remindersFooter(senders, macName)} They follow your reminder settings above.`

  return (
    <>
      <Section title="This Device">
        <label className="row">
          <span className="row-main" style={{ flex: 'none' }}>
            <span className="row-title">Name</span>
          </span>
          <input
            className="inline"
            style={{ flex: 1 }}
            defaultValue={meta.deviceName ?? ''}
            placeholder="e.g. Ana’s iPhone"
            onBlur={(e) => void setMeta('deviceName', e.currentTarget.value.trim())}
            enterKeyHint="done"
          />
        </label>
        <Row
          title="I am"
          value={me ? me.name : people.length ? 'Choose…' : 'Nobody yet'}
          chevron={people.length > 0}
          onClick={people.length ? () => setPicking(true) : undefined}
        />
      </Section>

      <PeopleSection />
      {me && <RemindersSection me={me} />}

      <ReplaceHouseholdBanner />
      <Section
        title="Sync at Home"
        footer={
          paired
            ? status.hint
            : 'On your Mac, open Upkeep › Settings › Phones › Pair a Phone… and enter the code shown there. You need to be on your home Wi-Fi.'
        }
      >
        <Row
          leading={
            <span className={`status-tone ${status.tone}`}>
              <SyncGlyph status={status} width={24} height={24} style={{ display: 'block' }} />
            </span>
          }
          title={meta.macName || 'Your Mac'}
          subtitle={status.since}
          value={<span className={`status-tone ${status.tone}`}>{status.label}</span>}
          inset={52}
        />
        {paired && (
          <Row className="action" title="Sync Now" onClick={() => void LanTransport.sync()} inset={52} />
        )}
        {(!paired || lan.status === 'unauthorized') && <PairCodeEntry />}
      </Section>

      <Section
        title="Sync Away from Home"
        footer="Export: save it in iCloud Drive › Upkeep Household › devices. If iOS offers Replace or Keep Both, choose Replace. Import: pick all the files in that devices folder."
      >
        {stale && (
          <div className="row warn">
            <Warning width={22} height={22} style={{ color: 'var(--orange)', flex: 'none' }} />
            <span className="row-main" style={{ fontSize: 15 }}>
              Changes from this device haven’t reached anyone for {calendarDaysBetween(meta.firstUnsyncedChange!, now)} days. Sync at home or export.
            </span>
          </div>
        )}
        <Row
          className="action"
          leading={<Folder width={24} height={24} style={{ display: 'block' }} />}
          title="Import from Files…"
          subtitle={meta.lastImport ? `Last import ${relativeTime(meta.lastImport, now)}` : undefined}
          onClick={() => fileInput.current?.click()}
          inset={52}
        />
        <Row
          className="action"
          leading={<Folder width={24} height={24} style={{ display: 'block' }} />}
          title="Export to Files…"
          subtitle={meta.lastExport ? `Last export ${relativeTime(meta.lastExport, now)}` : undefined}
          onClick={() => void exportFile()}
          inset={52}
        />
        <input ref={fileInput} type="file" multiple accept=".json,application/json" className="sr-only" onChange={(e) => void onFiles(e.currentTarget.files)} />
      </Section>

      <Section title="Notifications" footer={pushMessage ?? pushHint}>
        <Row
          leading={<Bell width={24} height={24} style={{ color: pushOn ? 'var(--tint)' : 'var(--secondary)', display: 'block' }} />}
          title="Reminders"
          value={pushBusy ? '…' : pushOn ? 'On' : 'Off'}
          inset={52}
        />
        {me && <Row title={<span className="muted" style={{ fontSize: 15 }}>{describeReminders(me)}</span>} inset={52} />}
        {pushOn ? (
          <Row className="action" title="Turn Off" onClick={() => void togglePush(false)} inset={52} />
        ) : (
          <Row className="action" title="Turn On Notifications" onClick={isStandalone() && paired && !pushBusy ? () => void togglePush(true) : undefined} inset={52} />
        )}
      </Section>

      <AppearanceSection />

      <Section title="About">
        <Row title="Upkeep" value={`Version ${APP_VERSION}`} onClick={tapVersion} />
        <Row title="Build" value={`${BUILD_DATE === 'dev' ? 'dev' : formatDate(new Date(`${BUILD_DATE}T12:00:00Z`).getTime())} · ${BUILD_HASH}`} />
        <OfflineCopyRows />
        <Row
          className="action"
          title="Check for Updates"
          onClick={() =>
            void checkForUpdate().then((ok) => toast(ok ? 'Checked. If there’s an update, you’ll see a Reload button.' : 'Updates are checked when Upkeep is installed.'))
          }
        />
        <Row className="action" title="Homepage" onClick={() => window.open('https://bostjan-cigan.com', '_blank', 'noopener')} />
      </Section>
      <p className="section-footer" style={{ textAlign: 'center', marginTop: -14, marginBottom: 26 }}>Created with passion on a rainy day by Boštjan Cigan.</p>

      {(unlocked === '1' || demo) && (
        <Section
          title="Developer"
          footer={
            demo
              ? 'This device is showing the sample household. Erase it when you’re done, then pair again to get your own.'
              : 'The sample household is a self-contained pretend home for showing Upkeep to someone. Loading it erases this device first and leaves it unpaired, so nothing here can reach your Mac.'
          }
        >
          <Row
            className="action"
            leading={<House width={24} height={24} style={{ display: 'block' }} />}
            title={demo ? 'Reload the Sample Household' : 'Load the Sample Household'}
            subtitle={demo ? 'Showing demo data' : undefined}
            onClick={() => setConfirming('demo')}
            inset={52}
          />
          <Row
            className="destructive"
            leading={<Warning width={24} height={24} style={{ display: 'block' }} />}
            title="Erase All Data on This Device"
            onClick={() => setConfirming('erase')}
            inset={52}
          />
          <Row title="Device ID" subtitle={meta.deviceId} />
          <Row title="Paired" value={paired ? 'Yes' : 'No'} />
        </Section>
      )}

      {confirming === 'demo' && (
        <ConfirmSheet
          title="Sample Household"
          message={
            <>
              Everything on this device is erased first — its copy of the household, its pairing and who you
              are — and replaced by a pretend home with two people, eight things and a year of history.
              {paired && ' This device will need pairing again afterwards.'} Your household itself is untouched:
              every other device still has it.
            </>
          }
          confirm="Erase and Load Sample"
          destructive
          busy={working}
          onConfirm={() => void runDemo()}
          onClose={() => setConfirming(null)}
        />
      )}

      {confirming === 'erase' && (
        <ConfirmSheet
          title="Erase This Device"
          message={
            <>
              Removes this device’s copy of the household, its pairing, who you are and its reminders. The
              household itself is untouched — the Macs and the other phones still have it, and this device can
              pair again and sync it all back.
              {stale && ' Changes made here that haven’t reached anyone yet will be lost.'}
            </>
          }
          confirm="Erase Everything"
          destructive
          busy={working}
          onConfirm={() => void runErase()}
          onClose={() => setConfirming(null)}
        />
      )}

      {picking && (
        <Sheet title="Who are you?" onClose={() => setPicking(false)} auto>
          <p className="section-footer" style={{ padding: '4px 4px 14px' }}>Your tasks and reminders follow the person you pick. Not listed? Add yourself in People.</p>
          <PersonPicker
            people={people}
            selected={myUid}
            onPick={(uid) => {
              void setMyPerson(uid)
              setPicking(false)
            }}
          />
        </Sheet>
      )}

      {exportResult && (
        <Sheet title="Exported" onClose={() => setExportResult(null)} auto>
          <p style={{ margin: '4px 4px 6px', fontSize: 17 }}>
            Saved <strong>{exportResult.name}</strong> — this device’s file for the household, with {exportResult.records}{' '}
            items, tasks and history entries.
          </p>
          {exportResult.how === 'downloaded' ? (
            <p className="section-footer">
              It went to Downloads. Move it into iCloud Drive › Upkeep Household › devices, replacing the file that’s
              already there.
            </p>
          ) : (
            <p className="section-footer">
              Put it in iCloud Drive › Upkeep Household › devices. If iOS offers <strong>Replace</strong> or Keep Both,
              choose Replace — a second copy just sits there going stale.
            </p>
          )}
          <p className="section-footer">Every Mac in your household picks it up on its own next sync. Nothing else to do.</p>
        </Sheet>
      )}

      {importResult && (
        <Sheet title="Import" onClose={() => setImportResult(null)} auto>
          <p style={{ margin: '4px 4px 16px', fontSize: 17 }}>{describeImport(importResult)}</p>
          <div className="card">
            {importResult.files.map((f, i) => (
              <Row key={i} title={f.name} subtitle={f.ok ? f.device : f.error} value={f.ok ? '✓' : '✕'} />
            ))}
          </div>
          <p className="section-footer">Now export this device’s file so the others get your changes.</p>
        </Sheet>
      )}
    </>
  )
}
