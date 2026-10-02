import { describe, expect, it } from 'vitest'
import {
  asAppearance,
  asPreference,
  resolveAppearance,
  type AppearanceCapabilities,
  type AppearancePreference,
} from '../src/app/appearance'

const caps = (backdrop: boolean, reducedTransparency: boolean): AppearanceCapabilities => ({
  backdrop,
  reducedTransparency,
})

describe('resolveAppearance', () => {
  const prefs: AppearancePreference[] = ['auto', 'glass', 'classic']

  it('falls back to classic wherever the device cannot blur', () => {
    for (const pref of prefs) {
      expect(resolveAppearance(pref, caps(false, false))).toBe('classic')
      expect(resolveAppearance(pref, caps(false, true))).toBe('classic')
    }
  })

  it('lets Reduce Transparency win, even over an explicit glass choice', () => {
    for (const pref of prefs) {
      expect(resolveAppearance(pref, caps(true, true))).toBe('classic')
    }
  })

  it('prefers glass on a capable device', () => {
    expect(resolveAppearance('auto', caps(true, false))).toBe('glass')
    expect(resolveAppearance('glass', caps(true, false))).toBe('glass')
  })

  it('honours an explicit classic choice on a capable device', () => {
    expect(resolveAppearance('classic', caps(true, false))).toBe('classic')
  })
})

describe('asPreference', () => {
  it('passes the three known values through', () => {
    expect(asPreference('auto')).toBe('auto')
    expect(asPreference('glass')).toBe('glass')
    expect(asPreference('classic')).toBe('classic')
  })

  it('treats anything else as auto', () => {
    for (const raw of [null, undefined, '', 'Glass', 'frosted', '1']) {
      expect(asPreference(raw)).toBe('auto')
    }
  })
})

describe('asAppearance', () => {
  it('accepts only a resolved look', () => {
    expect(asAppearance('glass')).toBe('glass')
    expect(asAppearance('classic')).toBe('classic')
    for (const raw of [null, undefined, '', 'auto', 'Classic']) {
      expect(asAppearance(raw)).toBeUndefined()
    }
  })
})
