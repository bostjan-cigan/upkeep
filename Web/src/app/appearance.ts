/**
 * Which look the app wears. The frosted "glass" appearance needs `backdrop-filter`, so it
 * is a capability, not just a taste — hence the split between what the person picked and
 * what we can actually draw.
 */

/** What the person chose in Settings. 'auto' lets the device decide. */
export type AppearancePreference = 'auto' | 'glass' | 'classic'

/** What the app actually renders. Always what `<html data-appearance>` holds. */
export type Appearance = 'glass' | 'classic'

export const APPEARANCE_KEY = 'upkeep.appearance'
/** Last resolved value, so the pre-paint script in index.html need not redo the reasoning. */
export const RESOLVED_KEY = 'upkeep.appearance.resolved'

/** Everything about the device the choice depends on, as plain data so tests can fake it. */
export interface AppearanceCapabilities {
  /** This browser can blur what is painted behind an element. */
  backdrop: boolean
  /** Accessibility › Reduce Transparency, or its equivalent elsewhere. */
  reducedTransparency: boolean
}

/**
 * The whole decision, in one place.
 *
 * Reduce Transparency beats an explicit 'glass': it is a setting someone turned on
 * deliberately, and an app toggle is not the place to overrule it. Settings says so in its
 * footer rather than silently ignoring the choice.
 */
export function resolveAppearance(pref: AppearancePreference, caps: AppearanceCapabilities): Appearance {
  if (!caps.backdrop) return 'classic'
  if (caps.reducedTransparency) return 'classic'
  return pref === 'classic' ? 'classic' : 'glass'
}

/** An old build's value, a hand-edited key, a null: all mean 'auto'. */
export function asPreference(raw: string | null | undefined): AppearancePreference {
  return raw === 'glass' || raw === 'classic' || raw === 'auto' ? raw : 'auto'
}

/** An old build's value or a hand-edited key: anything but the two looks is unusable. */
export function asAppearance(raw: string | null | undefined): Appearance | undefined {
  return raw === 'glass' || raw === 'classic' ? raw : undefined
}
