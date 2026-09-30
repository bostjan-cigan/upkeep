// Touch-first, iOS-flavoured building blocks.
import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { TILE_COLOR_HEX, tileForeground, type Person } from '../core/people'
import { ChevronLeft, ChevronRight, Disclosure } from './icons'

export function Screen({
  title,
  left,
  right,
  children,
  largeTitle = true,
}: {
  title: string
  left?: ReactNode
  right?: ReactNode
  children: ReactNode
  largeTitle?: boolean
}) {
  const [scrolled, setScrolled] = useState(!largeTitle)
  // Whether anything is actually behind the bar. Separate from `scrolled`, which is about the
  // title swap and is on from the start where there is no large title to shrink.
  const [overContent, setOverContent] = useState(false)
  useEffect(() => {
    const onScroll = () => {
      if (largeTitle) setScrolled(window.scrollY > 36)
      setOverContent(window.scrollY > 4)
    }
    onScroll()
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [largeTitle])
  return (
    <>
      <header className={`topbar${scrolled ? ' scrolled' : ''}${overContent ? ' over-content' : ''}`}>
        <div className="topbar-inner">
          <div className="topbar-side">{left}</div>
          <div className="topbar-title">{title}</div>
          <div className="topbar-side right">{right}</div>
        </div>
      </header>
      <main className="screen">
        {largeTitle && <h1 className="large-title">{title}</h1>}
        {children}
      </main>
    </>
  )
}

export function BackButton({ label, onClick }: { label: string; onClick: () => void }) {
  return (
    <button className="bar-button back" onClick={onClick}>
      <ChevronLeft />
      {label}
    </button>
  )
}

export function Section({
  title,
  footer,
  action,
  big = false,
  children,
}: {
  title?: ReactNode
  footer?: ReactNode
  action?: ReactNode
  big?: boolean
  children: ReactNode
}) {
  return (
    <section className="section">
      {(title || action) && (
        <div className="section-header">
          {title ? <h2 className={`section-title${big ? ' big' : ''}`}>{title}</h2> : <span />}
          {action}
        </div>
      )}
      <div className="card">{children}</div>
      {footer && <p className="section-footer">{footer}</p>}
    </section>
  )
}

export function Row({
  title,
  subtitle,
  value,
  leading,
  trailing,
  onClick,
  chevron,
  className = '',
  inset,
}: {
  title: ReactNode
  subtitle?: ReactNode
  value?: ReactNode
  leading?: ReactNode
  trailing?: ReactNode
  onClick?: () => void
  chevron?: boolean
  className?: string
  inset?: number
}) {
  const content = (
    <>
      {leading && <span className="row-icon">{leading}</span>}
      <span className="row-main">
        <span className="row-title" style={{ display: 'block' }}>{title}</span>
        {subtitle && <span className="row-sub" style={{ display: 'block' }}>{subtitle}</span>}
      </span>
      {value !== undefined && <span className="row-value">{value}</span>}
      {trailing}
      {chevron && <ChevronRight className="row-chevron" />}
    </>
  )
  const style = inset ? ({ '--inset': `${inset}px` } as CSSProperties) : undefined
  return onClick ? (
    <button className={`row ${className}`} onClick={onClick} style={style}>
      {content}
    </button>
  ) : (
    <div className={`row ${className}`} style={style}>
      {content}
    </div>
  )
}

export function Segmented<T extends string>({
  options,
  value,
  onChange,
  label,
}: {
  options: { value: T; label: string }[]
  value: T
  onChange: (v: T) => void
  label: string
}) {
  return (
    <div className="segmented" role="radiogroup" aria-label={label}>
      {options.map((o) => (
        <button key={o.value} role="radio" aria-checked={o.value === value} className={o.value === value ? 'on' : ''} onClick={() => onChange(o.value)}>
          {o.label}
        </button>
      ))}
    </div>
  )
}

export function Avatar({ person, size = 22 }: { person: Pick<Person, 'name' | 'color'>; size?: number }) {
  const initial = [...person.name.trim()][0] ?? '?'
  return (
    <span className="avatar" title={person.name} style={{ width: size, height: size, fontSize: size * 0.5, background: TILE_COLOR_HEX[person.color], color: tileForeground(person.color) }}>
      {initial}
    </span>
  )
}

export function CollapsibleHeader({ title, badge, open, onToggle }: { title: string; badge?: string; open: boolean; onToggle: () => void }) {
  return (
    <button className={`collapsible${open ? ' open' : ''}`} onClick={onToggle} aria-expanded={open}>
      <Disclosure />
      <h2>{title}</h2>
      {badge && <span className="pill">{badge}</span>}
    </button>
  )
}

export function Sheet({
  title,
  onClose,
  left,
  right,
  auto = false,
  still = false,
  children,
}: {
  title: string
  onClose: () => void
  left?: ReactNode
  right?: ReactNode
  auto?: boolean
  /** Appears in place, for a sheet that takes over from another rather than arriving fresh. */
  still?: boolean
  children: ReactNode
}) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    document.addEventListener('keydown', onKey)
    const overflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    ref.current?.focus()
    return () => {
      document.removeEventListener('keydown', onKey)
      document.body.style.overflow = overflow
    }
  }, [onClose])
  return createPortal(
    <div className="sheet-layer" role="dialog" aria-modal="true" aria-label={title}>
      <div className="sheet-scrim" onClick={onClose} />
      <div className={`sheet${auto ? ' auto' : ''}${still ? ' still' : ''}`} ref={ref} tabIndex={-1}>
        <div className="sheet-bar">
          <div className="topbar-side">{left}</div>
          <h1>{title}</h1>
          <div className="topbar-side right">{right ?? <button className="bar-button bold" onClick={onClose}>Done</button>}</div>
        </div>
        <div className="sheet-body">{children}</div>
      </div>
    </div>,
    document.body,
  )
}

export function Toast({ message, action, onDone }: { message: string; action?: { label: string; run: () => void }; onDone: () => void }) {
  useEffect(() => {
    const timer = setTimeout(onDone, 5000)
    return () => clearTimeout(timer)
  }, [message, onDone])
  return createPortal(
    <div className="update-banner" role="status" aria-live="polite">
      <span style={{ flex: 1, minWidth: 0 }}>{message}</span>
      {action && (
        <button
          className="button small tinted"
          onClick={() => {
            action.run()
            onDone()
          }}
        >
          {action.label}
        </button>
      )}
    </div>,
    document.body,
  )
}
