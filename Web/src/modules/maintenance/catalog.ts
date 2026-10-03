// The item catalog from Upkeep/Modules/Maintenance/Catalog.swift: icon keys (one SVG each in
// Upkeep/Icons) and the ready-made items with their suggested routines. Icon keys are stored in
// synced data, so never rename one. templates.json is checked against the Mac's catalog by
// Tools/test-core.sh, so the two can't drift apart.
import type { TileColor } from '../../core/people'
import catalog from './templates.json'

export const ICON_KEYS = [
  'dishwasher', 'fridge', 'oven', 'stove', 'hood', 'microwave', 'coffee', 'kettle', 'jug', 'trash', 'washer', 'dryer', 'iron', 'shower', 'toilet', 'faucet', 'window', 'door', 'floor', 'rug', 'sofa', 'curtains', 'bed', 'lamp', 'tv', 'router', 'ac', 'radiator', 'waterheater', 'purifier', 'humidifier', 'fan', 'vacuum', 'stickvac', 'duster', 'smoke', 'extinguisher', 'firstaid', 'plant', 'balcony', 'paw', 'generic',
] as const
export type IconKey = (typeof ICON_KEYS)[number]

export function iconKey(value: unknown): IconKey {
  return (ICON_KEYS as readonly string[]).includes(value as string) ? (value as IconKey) : 'generic'
}

export type IntervalUnit = 'day' | 'week' | 'month' | 'year'
export const INTERVAL_UNITS: IntervalUnit[] = ['day', 'week', 'month', 'year']

export interface TaskSuggestion {
  title: string
  value: number
  unit: IntervalUnit
}

export interface ItemTemplate {
  id: string
  name: string
  icon: IconKey
  color: TileColor
  category: string
  /** The room a new item of this kind usually goes in; empty for none. */
  room: string
  suggestions: TaskSuggestion[]
}

/** Categories in catalog order, as `[key, title]`. */
export const TEMPLATE_CATEGORIES = catalog.categories as [string, string][]

export const ITEM_TEMPLATES: ItemTemplate[] = catalog.templates.map((t) => ({
  id: t.id,
  name: t.name,
  icon: iconKey(t.icon),
  color: t.color as TileColor,
  category: t.category,
  room: t.room,
  suggestions: (t.suggestions as [string, number, IntervalUnit][]).map(([title, value, unit]) => ({ title, value, unit })),
}))

/** "Something Else": a blank item with no suggested routine. */
export const CUSTOM_TEMPLATE_ID = 'custom'

/** Rooms offered before the household has any of its own. */
export const ROOM_SUGGESTIONS = ['Kitchen', 'Bathroom', 'Living Room', 'Bedroom', 'Hallway', 'Balcony']

/** Templates matching a search by name or by one of their tasks, in catalog order. */
export function searchTemplates(query: string): ItemTemplate[] {
  const q = query.trim().toLocaleLowerCase()
  if (!q) return ITEM_TEMPLATES
  return ITEM_TEMPLATES.filter((t) => t.name.toLocaleLowerCase().includes(q) || t.suggestions.some((s) => s.title.toLocaleLowerCase().includes(q)))
}

/** Template suggestions for this kind of item that aren't part of its routine yet. */
export function missingSuggestions(icon: IconKey, existingTitles: readonly string[]): TaskSuggestion[] {
  const existing = new Set(existingTitles.map((t) => t.toLocaleLowerCase()))
  const seen = new Set<string>()
  return ITEM_TEMPLATES.filter((t) => t.icon === icon)
    .flatMap((t) => t.suggestions)
    .filter((s) => {
      const key = s.title.toLocaleLowerCase()
      if (existing.has(key) || seen.has(key)) return false
      seen.add(key)
      return true
    })
}
