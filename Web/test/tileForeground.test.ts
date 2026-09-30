import { describe, expect, it } from 'vitest'
import { TILE_COLORS, TILE_COLOR_HEX, tileForeground } from '../src/core/people'

/** WCAG relative luminance of a #rrggbb colour. */
function luminance(hex: string): number {
  const channel = (i: number) => {
    const c = parseInt(hex.slice(i, i + 2), 16) / 255
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
  }
  return 0.2126 * channel(1) + 0.7152 * channel(3) + 0.0722 * channel(5)
}

function contrast(a: number, b: number): number {
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05)
}

/** The mark composited over the tile, since the dark one is 80% black. */
function markLuminance(mark: string, tile: string): number {
  if (mark === '#fff') return 1
  const over = (i: number) => Math.round(parseInt(tile.slice(i, i + 2), 16) * 0.2)
  const hex = `#${[over(1), over(3), over(5)].map((v) => v.toString(16).padStart(2, '0')).join('')}`
  return luminance(hex)
}

describe('tileForeground', () => {
  it('keeps every person badge at 3:1 or better', () => {
    for (const color of TILE_COLORS) {
      const tile = TILE_COLOR_HEX[color]
      const ratio = contrast(luminance(tile), markLuminance(tileForeground(color), tile))
      expect(ratio, `${color} (${tile})`).toBeGreaterThanOrEqual(3)
    }
  })

  it('would fail on the light colours if the mark were always white', () => {
    // Guards the premise: if the palette changes so white passes everywhere, this fix is moot.
    const failing = TILE_COLORS.filter((c) => contrast(luminance(TILE_COLOR_HEX[c]), 1) < 3)
    expect(failing).toEqual(['teal', 'green', 'yellow', 'orange'])
    for (const color of failing) expect(tileForeground(color)).not.toBe('#fff')
  })

  it('leaves the conventional white mark where it is legible', () => {
    for (const color of ['blue', 'red', 'pink', 'purple', 'indigo', 'brown'] as const) {
      expect(tileForeground(color)).toBe('#fff')
    }
  })
})
