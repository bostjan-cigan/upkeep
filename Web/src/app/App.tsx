import { useCallback, useEffect, useMemo, useState } from 'react'
import { useRegisterSW } from 'virtual:pwa-register/react'
import { deviceId } from '../core/db'
import { startOfflineCopy } from '../core/offline'
import { setRegistration, setUpdater } from '../core/pwa'
import { consumePairingFragment, isStale, LanTransport, startAutoSync } from '../core/sync'
import { attentionCount } from '../modules/maintenance'
import { ItemDetail } from '../modules/maintenance/screens/ItemDetail'
import { Calendar } from '../modules/maintenance/screens/Calendar'
import { AddItemSheet } from '../modules/maintenance/screens/ItemSheets'
import { Items } from '../modules/maintenance/screens/Items'
import { TaskEditorSheet } from '../modules/maintenance/screens/TaskEditorSheet'
import { UpNext } from '../modules/maintenance/screens/UpNext'
import { setBadge } from './badge'
import { AppContext, useHouseholdQuery, useMetaQuery, useNow, type AppContextValue } from './hooks'
import { CalendarIcon, Checklist, Gear, House, HouseFill, Person, Plus, Warning } from './icons'
import { Onboarding } from './Onboarding'
import { OfflineCopyBanner } from './OfflineCopy'
import { ReplaceHouseholdBanner } from './ReplaceHousehold'
import { Settings } from './Settings'
import { InstallScreen, shouldShowInstall } from './Install'
import { SyncPill } from './SyncStatus'
import { BackButton, Screen, Toast } from './ui'

type Tab = 'upNext' | 'calendar' | 'items' | 'settings'

const TABS: { id: Tab; title: string }[] = [
  { id: 'upNext', title: 'Up Next' },
  { id: 'calendar', title: 'Calendar' },
  { id: 'items', title: 'Items' },
  { id: 'settings', title: 'Settings' },
]

interface ToastState {
  id: number
  message: string
  action?: { label: string; run: () => void }
}

export function App() {
  const now = useNow()
  const household = useHouseholdQuery(now)
  const meta = useMetaQuery()
  const [tab, setTab] = useState<Tab>('upNext')
  /** Item detail pushed on top of the current tab. */
  const [itemUid, setItemUid] = useState<string | null>(null)
  const [toast, setToast] = useState<ToastState | null>(null)
  const [showInstall, setShowInstall] = useState(shouldShowInstall)
  const [adding, setAdding] = useState<'item' | 'task' | null>(null)

  useEffect(startOfflineCopy, [])

  // Pairing link from the Mac's QR code, then keep in sync with the Mac.
  useEffect(() => {
    let stop: (() => void) | undefined
    void deviceId()
    void consumePairingFragment().then((paired) => {
      stop = startAutoSync()
      if (paired) void LanTransport.sync()
    })
    return () => stop?.()
  }, [])

  const {
    needRefresh: [needRefresh],
    updateServiceWorker,
  } = useRegisterSW({
    onRegisteredSW(_url, registration) {
      setRegistration(registration)
      // Look for a new version whenever the app comes back to the foreground.
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'visible') void registration?.update().catch(() => undefined)
      })
    },
  })
  useEffect(() => setUpdater(updateServiceWorker), [updateServiceWorker])

  const myUid = meta?.myPersonUid && household?.people.some((p) => p.uid === meta.myPersonUid) ? meta.myPersonUid : ''
  const badge = household ? attentionCount(household, myUid, now) : 0
  useEffect(() => {
    if (household) setBadge(badge)
  }, [badge, household])

  const showToast = useCallback((message: string, action?: ToastState['action']) => {
    setToast({ id: Date.now(), message, action })
  }, [])
  const hideToast = useCallback(() => setToast(null), [])

  const openItem = useCallback((uid: string) => {
    setItemUid(uid)
    window.scrollTo(0, 0)
  }, [])

  const context = useMemo<AppContextValue | null>(
    () =>
      household && meta
        ? { household, meta, now, myUid, me: household.people.find((p) => p.uid === myUid), openItem, toast: showToast }
        : null,
    [household, meta, now, myUid, openItem, showToast],
  )

  if (!context || !household || !meta) return null

  if (showInstall) return <InstallScreen onSkip={() => setShowInstall(false)} />

  if (!meta.onboarded) {
    return (
      <AppContext.Provider value={context}>
        <Onboarding people={household.people} paired={!!meta.pairToken} hasData={household.items.length > 0} />
      </AppContext.Provider>
    )
  }

  const selectTab = (next: Tab) => {
    if (next === tab && itemUid) setItemUid(null)
    else {
      setTab(next)
      setItemUid(null)
    }
    window.scrollTo(0, 0)
  }

  const tabTitle = TABS.find((t) => t.id === tab)!.title
  const item = itemUid ? household.itemsByUid.get(itemUid) : undefined
  // Every screen carries the same live indicator: connected at home, syncing, or away.
  const syncPill = <SyncPill onOpenSettings={() => selectTab('settings')} />
  // Something new: a task when there's something to hang it on, otherwise the first item.
  const addButton = (what: 'item' | 'task') => (
    <>
      {syncPill}
      <button className="bar-button icon" onClick={() => setAdding(what === 'task' && !household.items.length ? 'item' : what)} aria-label={what === 'item' ? 'Add Item' : 'Add Task'}>
        <Plus />
      </button>
    </>
  )

  const staleBanner =
    isStale(meta.firstUnsyncedChange, now) ? (
      <div className="banner warn">
        <Warning style={{ color: 'var(--orange)' }} />
        <span className="grow">Your recent changes haven’t reached your household yet.</span>
        <button className="button small tinted" onClick={() => selectTab('settings')}>
          Sync
        </button>
      </div>
    ) : null
  const demoBanner = meta.demoMode ? (
    <div className="banner indigo">
      <House style={{ color: 'var(--indigo)' }} />
      <span className="grow">Sample household — for a look around. None of it is yours.</span>
      <button className="button small tinted" onClick={() => selectTab('settings')}>
        Erase
      </button>
    </div>
  ) : null
  const whoBanner =
    !myUid && household.people.length > 0 ? (
      <div className="banner info">
        <Person style={{ color: 'var(--tint)' }} />
        <span className="grow">Tell Upkeep who you are to see your tasks first.</span>
        <button className="button small tinted" onClick={() => selectTab('settings')}>
          Choose
        </button>
      </div>
    ) : null

  let screen
  if (itemUid) {
    screen = (
      <Screen key={`item-${itemUid}`} title={item?.name ?? 'Item'} largeTitle={false} left={<BackButton label={tabTitle} onClick={() => setItemUid(null)} />} right={syncPill}>
        <ItemDetail uid={itemUid} onDeleted={() => setItemUid(null)} />
      </Screen>
    )
  } else if (tab === 'upNext') {
    screen = (
      <Screen key="upNext" title="Up Next" right={addButton('task')}>
        <UpNext
          onAddItem={() => setAdding('item')}
          banner={
            <>
              {demoBanner}
              <OfflineCopyBanner />
              <ReplaceHouseholdBanner />
              {whoBanner}
              {staleBanner}
            </>
          }
        />
      </Screen>
    )
  } else if (tab === 'calendar') {
    screen = (
      <Screen key="calendar" title="Calendar" right={syncPill}>
        <Calendar />
      </Screen>
    )
  } else if (tab === 'items') {
    screen = (
      <Screen key="items" title="Items" right={addButton('item')}>
        <Items onAdd={() => setAdding('item')} />
      </Screen>
    )
  } else {
    screen = (
      <Screen key="settings" title="Settings" right={syncPill}>
        <Settings />
      </Screen>
    )
  }

  return (
    <AppContext.Provider value={context}>
      <div className="app">{screen}</div>
      <nav className="tabbar" aria-label="Sections">
        <div className="tabbar-inner">
          {TABS.map((t) => {
            const active = t.id === tab
            const Icon = t.id === 'upNext' ? Checklist : t.id === 'calendar' ? CalendarIcon : t.id === 'items' ? (active ? HouseFill : House) : Gear
            return (
              <button key={t.id} className={`tab${active ? ' active' : ''}`} onClick={() => selectTab(t.id)} aria-current={active ? 'page' : undefined}>
                <Icon />
                {t.title}
                {t.id === 'upNext' && badge > 0 && <span className="tab-badge">{badge}</span>}
              </button>
            )
          })}
        </div>
      </nav>
      {needRefresh && !toast && (
        <div className="update-banner" role="status">
          <span style={{ flex: 1 }}>
            <strong>Update available</strong>
            <br />
            <span className="muted">A new version of Upkeep is ready.</span>
          </span>
          <button className="button small primary" onClick={() => void updateServiceWorker(true)}>
            Reload
          </button>
        </div>
      )}
      {adding === 'item' && (
        <AddItemSheet
          onClose={() => setAdding(null)}
          onCreated={(uid) => {
            setAdding(null)
            openItem(uid)
          }}
        />
      )}
      {adding === 'task' && <TaskEditorSheet onClose={() => setAdding(null)} />}
      {toast && <Toast key={toast.id} message={toast.message} action={toast.action} onDone={hideToast} />}
    </AppContext.Provider>
  )
}
