import {
  APPEARANCE_KEY,
  RESOLVED_KEY,
  asPreference,
  resolveAppearance,
  type Appearance,
  type AppearanceCapabilities,
  type AppearancePreference,
} from './appearance'

/** Status bar tint behind the bars, per look. iOS reads this around launch. */
const THEME_COLOURS: Record<Appearance, { light: string; dark: string }> = {
  classic: { light: '#F2F2F7', dark: '#000000' },
  glass: { light: '#EEF0F6', dark: '#07070A' },
}

const REDUCED_TRANSPARENCY = '(prefers-reduced-transparency: reduce)'

export interface AppearanceState {
  pref: AppearancePreference
  resolved: Appearance
  /** Both surfaced in Settings, to explain why an explicit choice did not take. */
  reducedTransparency: boolean
  backdrop: boolean
}

function readCapabilities(): AppearanceCapabilities {
  const supports = (property: string, value: string) => typeof CSS !== 'undefined' && !!CSS.supports?.(property, value)
  return {
    backdrop: supports('backdrop-filter', 'blur(1px)') || supports('-webkit-backdrop-filter', 'blur(1px)'),
    reducedTransparency: matchMedia(REDUCED_TRANSPARENCY).matches,
  }
}

function readPreference(): AppearancePreference {
  try {
    return asPreference(localStorage.getItem(APPEARANCE_KEY))
  } catch {
    // Private mode.
    return 'auto'
  }
}

function compute(pref: AppearancePreference): AppearanceState {
  const caps = readCapabilities()
  return { pref, resolved: resolveAppearance(pref, caps), ...caps }
}

let state: AppearanceState = compute(readPreference())
const listeners = new Set<() => void>()

function applyThemeColour(resolved: Appearance) {
  const set = (media: string, colour: string) =>
    document
      .querySelector<HTMLMetaElement>(`meta[name="theme-color"][media="${media}"]`)
      ?.setAttribute('content', colour)
  const { light, dark } = THEME_COLOURS[resolved]
  set('(prefers-color-scheme: light)', light)
  set('(prefers-color-scheme: dark)', dark)
}

function publish(pref: AppearancePreference) {
  state = compute(pref)
  document.documentElement.setAttribute('data-appearance', state.resolved)
  applyThemeColour(state.resolved)
  try {
    // What the pre-paint script in index.html reads next launch, so it never guesses twice.
    localStorage.setItem(RESOLVED_KEY, state.resolved)
  } catch {
    // Private mode.
  }
  for (const l of listeners) l()
}

export function getAppearance(): AppearanceState {
  return state
}

export function subscribeAppearance(listener: () => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

export function setAppearancePreference(pref: AppearancePreference) {
  try {
    localStorage.setItem(APPEARANCE_KEY, pref)
  } catch {
    // Private mode: keep it for this run.
  }
  publish(pref)
}

// Applied at import time, before React's first commit, so nothing renders in the wrong look.
publish(state.pref)
matchMedia(REDUCED_TRANSPARENCY).addEventListener('change', () => publish(state.pref))
