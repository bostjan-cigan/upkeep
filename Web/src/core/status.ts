// One reading of "how is this phone doing with the Mac", shared by the indicator in the
// navigation bar and the row in Settings, so they can never disagree. Pure: no DOM, no clock —
// everything it needs is passed in.
import { relativeTime } from './dates'
import type { LanState } from './sync'

export type SyncTone = 'ok' | 'busy' | 'offline' | 'warn'

export type SyncKind = 'connected' | 'synced' | 'syncing' | 'pending' | 'offline' | 'away' | 'notPaired' | 'problem' | 'demo'

export interface SyncStatus {
  kind: SyncKind
  /** One or two words for the pill. */
  label: string
  /** One short line naming the state, for the indicator's label in VoiceOver. */
  detail: string
  /** When the Mac was last heard from — for a row that already names the Mac. */
  since: string
  /** A sentence explaining what it means and what happens next. */
  hint: string
  tone: SyncTone
  /** Edits made here that the household hasn't seen yet — a dot on the indicator. */
  waiting: boolean
}

export interface SyncInputs {
  lan: LanState
  paired: boolean
  /** `navigator.onLine`: false means this device has no network at all. */
  online: boolean
  lastLanSync?: number
  macName?: string
  /** True for a few seconds after a round trip, so a sync the user caused is visible. */
  justSynced?: boolean
  /** `firstUnsyncedChange`: local edits still waiting to reach the household. */
  pendingChanges?: boolean
  /** Showing the sample household: there is no Mac to be at home with. */
  demo?: boolean
  now: number
}

export function syncStatus(inputs: SyncInputs): SyncStatus {
  const { lan, paired, online, lastLanSync, macName, justSynced, pendingChanges, now } = inputs
  const mac = macName || 'your Mac'
  const waiting = !!pendingChanges
  const ago = lastLanSync ? `last synced ${relativeTime(lastLanSync, now)}` : ''
  const since = lastLanSync ? `Last synced ${relativeTime(lastLanSync, now)}` : 'Not synced yet'

  if (inputs.demo) {
    return {
      kind: 'demo',
      label: 'Demo',
      detail: 'Sample household',
      since: 'Nothing to sync',
      hint: 'This device is showing the sample household. Nothing here is synced with anybody — erase it in Settings when you’re done.',
      tone: 'offline',
      waiting: false,
    }
  }
  if (!paired) {
    return {
      kind: 'notPaired',
      label: 'Not paired',
      detail: 'Not paired with a Mac',
      since,
      hint: `Pair this device with ${macName ? mac : 'your Mac'} to sync over your home Wi-Fi.`,
      tone: 'warn',
      waiting,
    }
  }

  switch (lan.status) {
    case 'pending':
      return {
        kind: 'pending',
        label: 'Saving…',
        detail: 'Saving your changes',
        since,
        hint: `Your change is saved on this device and is on its way to ${mac}.`,
        tone: 'busy',
        waiting: false,
      }

    case 'syncing':
      return {
        kind: 'syncing',
        label: 'Syncing…',
        detail: 'Syncing',
        since,
        hint: `Exchanging changes with ${mac} over your home Wi-Fi.`,
        tone: 'busy',
        waiting: false,
      }

    case 'otherHousehold':
      return {
        kind: 'problem',
        label: 'Other household',
        detail: 'Holding another household’s copy',
        since,
        hint: lan.message ?? `This phone still has another household’s items. Replace them with ${mac}’s household in Settings.`,
        tone: 'warn',
        waiting,
      }

    case 'unauthorized':
    case 'macNeedsUpdate':
    case 'updating':
    case 'error':
      return {
        kind: 'problem',
        label: 'Sync issue',
        detail: lan.message ?? 'Couldn’t sync',
        since,
        hint: lan.message ?? `Upkeep couldn’t sync with ${mac}.`,
        tone: 'warn',
        waiting,
      }

    case 'unreachable':
    case 'idle':
    case 'notPaired': {
      // Paired, but nothing is reaching the Mac: either this device has no network at all, or
      // it's somewhere else — or the Mac is asleep. Everything keeps working either way.
      if (!online) {
        return {
          kind: 'offline',
          label: 'Offline',
          detail: ago ? `Offline · ${ago}` : 'Offline',
          since,
          hint: waiting
            ? 'This device has no network. Your changes are saved here and go to the household the moment you’re back on your home Wi-Fi.'
            : 'This device has no network. Upkeep works offline; it syncs again the moment you’re back on your home Wi-Fi.',
          tone: 'offline',
          waiting,
        }
      }
      return {
        kind: 'away',
        label: 'Away',
        detail: ago ? `Away from home · ${ago}` : 'Away from home',
        since,
        hint: `Not on your home Wi-Fi, or ${mac} is asleep. Upkeep keeps working here${waiting ? ', and your changes go across as soon as you’re both home' : ''}.`,
        tone: 'offline',
        waiting,
      }
    }

    case 'ok': {
      if (justSynced) {
        const summary = lan.lastSummary
        const changed = summary ? summary.added + summary.updated + summary.removed : 0
        return {
          kind: 'synced',
          label: 'Synced',
          detail: `Connected to ${mac} · synced just now`,
          since: 'Synced just now',
          hint: changed
            ? `Synced with ${mac} just now — ${changed === 1 ? '1 change' : `${changed} changes`} came back.`
            : `Synced with ${mac} just now. Everything matches.`,
          tone: 'ok',
          waiting: false,
        }
      }
      return {
        kind: 'connected',
        label: 'At home',
        detail: ago ? `Connected to ${mac} · ${ago}` : `Connected to ${mac}`,
        since,
        hint: `On your home Wi-Fi. Upkeep syncs with ${mac} while you use it.`,
        tone: 'ok',
        waiting,
      }
    }
  }
}
