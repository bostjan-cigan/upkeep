// App-icon style tile: colored gradient squircle with a white glyph from Upkeep/Icons (shared with the Mac).
import { TILE_COLOR_HEX, type TileColor } from '../../core/people'
import { iconKey, type IconKey } from './catalog'

const urls = import.meta.glob('../../../../Upkeep/Icons/*.svg', { query: '?url', import: 'default', eager: true }) as Record<string, string>

const ICON_URLS: Partial<Record<IconKey, string>> = {}
for (const [path, url] of Object.entries(urls)) {
  const name = path.split('/').pop()!.replace(/\.svg$/, '')
  if (iconKey(name) === name) ICON_URLS[name as IconKey] = url
}

export function iconUrl(key: IconKey): string | undefined {
  return ICON_URLS[key] ?? ICON_URLS.generic
}

/** `color` mixed `amount` of the way towards white, like SwiftUI's `mix(with: .white, by:)`. */
export function mixWithWhite(hex: string, amount: number): string {
  const n = parseInt(hex.slice(1), 16)
  const channel = (shift: number) => {
    const c = (n >> shift) & 255
    return Math.round(c + (255 - c) * amount)
  }
  return `rgb(${channel(16)}, ${channel(8)}, ${channel(0)})`
}

export function tileBackground(color: TileColor): string {
  const hex = TILE_COLOR_HEX[color]
  return `linear-gradient(to bottom, ${mixWithWhite(hex, 0.25)}, ${hex})`
}

export function ItemTile({ icon, color, size = 40, dim = false }: { icon: IconKey; color: TileColor; size?: number; dim?: boolean }) {
  const url = iconUrl(icon)
  return (
    <span
      className="tile"
      aria-hidden="true"
      style={{
        width: size,
        height: size,
        borderRadius: size * 0.225,
        background: tileBackground(color),
        padding: size * 0.13,
        opacity: dim ? 0.5 : 1,
        boxShadow: `inset 0 0 0 ${Math.max(0.5, size / 80)}px rgba(255,255,255,0.18), 0 ${size * 0.03}px ${size * 0.08}px rgba(0,0,0,${size > 60 ? 0.18 : 0.12})`,
      }}
    >
      {url && <img src={url} alt="" draggable={false} />}
    </span>
  )
}
