import { useLiveQuery } from 'dexie-react-hooks'
import { createContext, useContext, useEffect, useMemo, useState, useSyncExternalStore } from 'react'
import { allMeta, db, type Meta } from '../core/db'
import { getOfflineCopy, subscribeOfflineCopy, type OfflineCopy } from '../core/offline'
import type { Person } from '../core/people'
import { getLanState, subscribeLan, type LanState } from '../core/sync'
import { getAppearance, subscribeAppearance, type AppearanceState } from './appearanceStore'
import { buildHousehold, type Household } from '../modules/maintenance/schedule'

/** Current time, refreshed every minute and whenever the app comes back to the foreground. */
export function useNow(intervalMs = 60_000): number {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const tick = () => setNow(Date.now())
    const timer = setInterval(tick, intervalMs)
    const onVisible = () => document.visibilityState === 'visible' && tick()
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      clearInterval(timer)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [intervalMs])
  return now
}

/** The household model, recomputed (derived fields included) after every merge and local change. */
export function useHouseholdQuery(now: number): Household | undefined {
  const records = useLiveQuery(() => db.records.toArray(), [])
  return useMemo(() => (records ? buildHousehold(records, now) : undefined), [records, now])
}

export function useMetaQuery(): Partial<Meta> | undefined {
  return useLiveQuery(allMeta, [])
}

export function useLanState(): LanState {
  return useSyncExternalStore(subscribeLan, getLanState)
}

/** Whether Upkeep can open on this device without reaching the Mac. */
export function useOfflineCopy(): OfflineCopy {
  return useSyncExternalStore(subscribeOfflineCopy, getOfflineCopy)
}

/** The look the app is wearing, and why. Shared, unlike `usePreference`. */
export function useAppearance(): AppearanceState {
  return useSyncExternalStore(subscribeAppearance, getAppearance)
}

export interface AppContextValue {
  household: Household
  meta: Partial<Meta>
  now: number
  myUid: string
  me: Person | undefined
  openItem: (uid: string) => void
  toast: (message: string, action?: { label: string; run: () => void }) => void
}

export const AppContext = createContext<AppContextValue | null>(null)

export function useApp(): AppContextValue {
  const value = useContext(AppContext)
  if (!value) throw new Error('useApp outside AppContext')
  return value
}

/** A per-device UI preference kept in localStorage (never synced). */
export function usePreference<T extends string>(key: string, fallback: T): [T, (v: T) => void] {
  const [value, setValue] = useState<T>(() => {
    try {
      return (localStorage.getItem(`upkeep.${key}`) as T | null) ?? fallback
    } catch {
      return fallback
    }
  })
  const set = (v: T) => {
    setValue(v)
    try {
      localStorage.setItem(`upkeep.${key}`, v)
    } catch {
      // Private mode: keep it in memory.
    }
  }
  return [value, set]
}
