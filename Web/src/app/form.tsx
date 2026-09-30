// Form rows for the editors, in the style of iOS grouped settings: a label on the left and the
// control on the right, or a field that fills the row.
import type { CSSProperties, ReactNode } from 'react'
import { fromDateInput, toDateInput, WEEKDAYS_LONG, WEEKDAYS_SHORT, type Millis } from '../core/dates'
import { TILE_COLOR_HEX, TILE_COLORS, tileForeground, type TileColor } from '../core/people'
import { firstWeekday } from '../modules/maintenance/calendar'
import { weekdaySet, weekdayString } from '../modules/maintenance/schedule'
import { CheckCircleFill } from './icons'
import { Sheet } from './ui'

export function Switch({ on, onChange, label }: { on: boolean; onChange: (on: boolean) => void; label: string }) {
  return (
    <button type="button" role="switch" aria-checked={on} aria-label={label} className={`switch${on ? ' on' : ''}`} onClick={() => onChange(!on)}>
      <span />
    </button>
  )
}

export function SwitchRow({ title, subtitle, on, onChange }: { title: string; subtitle?: string; on: boolean; onChange: (on: boolean) => void }) {
  return (
    <div className="row">
      <span className="row-main">
        <span className="row-title" style={{ display: 'block' }}>{title}</span>
        {subtitle && <span className="row-sub" style={{ display: 'block' }}>{subtitle}</span>}
      </span>
      <Switch on={on} onChange={onChange} label={title} />
    </div>
  )
}

/** A text field filling the row, with an optional label before it. */
export function TextRow({
  label,
  value,
  onChange,
  placeholder,
  autoFocus,
  onSubmit,
}: {
  label?: string
  value: string
  onChange: (v: string) => void
  placeholder?: string
  autoFocus?: boolean
  onSubmit?: () => void
}) {
  return (
    <label className="row">
      {label && <span className="row-title" style={{ flex: 'none', minWidth: 72 }}>{label}</span>}
      <input
        className="field"
        value={value}
        placeholder={placeholder}
        aria-label={label ?? placeholder}
        autoFocus={autoFocus}
        enterKeyHint="done"
        onChange={(e) => onChange(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter' && onSubmit) {
            e.preventDefault()
            onSubmit()
          }
        }}
      />
    </label>
  )
}

export function TextAreaRow({ value, onChange, placeholder }: { value: string; onChange: (v: string) => void; placeholder?: string }) {
  return (
    <label className="row">
      <textarea className="field" value={value} placeholder={placeholder} aria-label={placeholder} onChange={(e) => onChange(e.target.value)} />
    </label>
  )
}

/** A native picker, shown as the chosen value on the right of the row. */
export function SelectRow<T extends string | number>({
  title,
  value,
  options,
  onChange,
}: {
  title: string
  value: T
  options: { value: T; label: string }[]
  onChange: (v: T) => void
}) {
  return (
    <label className="row">
      <span className="row-main">
        <span className="row-title">{title}</span>
      </span>
      <select
        className="inline"
        aria-label={title}
        value={String(value)}
        onChange={(e) => {
          const picked = options.find((o) => String(o.value) === e.target.value)
          if (picked) onChange(picked.value)
        }}
      >
        {options.map((o) => (
          <option key={String(o.value)} value={String(o.value)}>
            {o.label}
          </option>
        ))}
      </select>
    </label>
  )
}

export function DateRow({ title, value, onChange, max }: { title: string; value: Millis; onChange: (v: Millis) => void; max?: Millis }) {
  return (
    <label className="row">
      <span className="row-main">
        <span className="row-title">{title}</span>
      </span>
      <input
        className="inline"
        type="date"
        aria-label={title}
        value={toDateInput(value)}
        max={max === undefined ? undefined : toDateInput(max)}
        onChange={(e) => {
          const parsed = fromDateInput(e.target.value)
          if (parsed !== null) onChange(parsed)
        }}
      />
    </label>
  )
}

/**
 * Toggleable weekday buttons from the locale's first weekday. The value is a digit string of
 * `Calendar` weekdays (1 = Sunday … 7 = Saturday), as stored in synced data.
 */
export function WeekdayPicker({ value, onChange, label }: { value: string; onChange: (v: string) => void; label: string }) {
  const start = firstWeekday()
  const selected = weekdaySet(value)
  return (
    <div className="weekdays" role="group" aria-label={label}>
      {Array.from({ length: 7 }, (_, i) => {
        const js = (start + i) % 7
        const digit = js + 1
        const on = selected.has(digit)
        return (
          <button
            key={digit}
            type="button"
            className={on ? 'on' : ''}
            aria-pressed={on}
            aria-label={WEEKDAYS_LONG[js]}
            onClick={() => {
              const next = new Set(selected)
              if (on) next.delete(digit)
              else next.add(digit)
              onChange(weekdayString(next))
            }}
          >
            {WEEKDAYS_SHORT[js]!.slice(0, 2)}
          </button>
        )
      })}
    </div>
  )
}

export function WeekdayRow({ title, value, onChange }: { title: string; value: string; onChange: (v: string) => void }) {
  return (
    <div className="row stacked">
      <span className="row-title">{title}</span>
      <WeekdayPicker value={value} onChange={onChange} label={title} />
    </div>
  )
}

export function ColorPicker({ value, onChange }: { value: TileColor; onChange: (c: TileColor) => void }) {
  return (
    <div className="swatches" role="radiogroup" aria-label="Color">
      {TILE_COLORS.map((c) => (
        <button
          key={c}
          type="button"
          role="radio"
          aria-checked={c === value}
          aria-label={c}
          className={c === value ? 'on' : ''}
          style={{ background: TILE_COLOR_HEX[c], color: tileForeground(c) }}
          onClick={() => onChange(c)}
        />
      ))}
    </div>
  )
}

/** One choice from a short list, with a check on the chosen one. */
export function ChoiceRows<T extends string>({
  value,
  options,
  onChange,
}: {
  value: T
  options: { value: T; label: ReactNode; leading?: ReactNode; subtitle?: string }[]
  onChange: (v: T) => void
}) {
  return (
    <>
      {options.map((o) => (
        <button key={o.value} type="button" className="row" onClick={() => onChange(o.value)} style={o.leading ? ({ '--inset': '56px' } as CSSProperties) : undefined}>
          {o.leading && <span className="row-icon">{o.leading}</span>}
          <span className="row-main">
            <span className="row-title" style={{ display: 'block', whiteSpace: 'normal' }}>{o.label}</span>
            {o.subtitle && <span className="row-sub" style={{ display: 'block' }}>{o.subtitle}</span>}
          </span>
          {o.value === value && <CheckCircleFill width={22} height={22} style={{ color: 'var(--tint)', flex: 'none' }} />}
        </button>
      ))}
    </>
  )
}

/** Asks before something that can't be undone. */
export function ConfirmSheet({
  title,
  message,
  confirm,
  destructive = false,
  busy = false,
  onConfirm,
  onClose,
  secondary,
}: {
  title: string
  message: ReactNode
  confirm: string
  destructive?: boolean
  busy?: boolean
  onConfirm: () => void
  onClose: () => void
  /** Another way out, such as "Pause Instead". */
  secondary?: { label: string; run: () => void }
}) {
  return (
    <Sheet title={title} onClose={onClose} auto right={<button className="bar-button" onClick={onClose}>Cancel</button>}>
      <p style={{ margin: '4px 4px 20px', fontSize: 17 }}>{message}</p>
      <button className={`button wide ${destructive ? 'destructive' : 'primary'}`} disabled={busy} onClick={onConfirm}>
        {busy ? 'Working…' : confirm}
      </button>
      {secondary && (
        <button className="button wide tinted" style={{ marginTop: 10 }} disabled={busy} onClick={secondary.run}>
          {secondary.label}
        </button>
      )}
    </Sheet>
  )
}
