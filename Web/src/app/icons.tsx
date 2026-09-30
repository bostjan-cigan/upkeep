// Small SF Symbols–style glyphs drawn inline so they follow `currentColor`.
import type { SVGProps } from 'react'

type P = SVGProps<SVGSVGElement>
const base = (p: P): P => ({ viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', strokeWidth: 1.9, strokeLinecap: 'round', strokeLinejoin: 'round', 'aria-hidden': true, ...p })

export const CheckCircle = (p: P) => (
  <svg {...base(p)}>
    <circle cx="12" cy="12" r="9.2" />
    <path d="M7.8 12.3l2.9 2.9 5.5-6" />
  </svg>
)

export const CheckCircleFill = (p: P) => (
  <svg {...base({ ...p, stroke: 'none' })}>
    <circle cx="12" cy="12" r="10.2" fill="currentColor" />
    <path d="M7.6 12.3l3 3 5.8-6.3" stroke="#fff" strokeWidth="2.2" fill="none" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
)

export const Seal = (p: P) => (
  <svg {...base({ ...p, stroke: 'none' })} viewBox="0 0 40 40">
    <path
      fill="currentColor"
      d="M20 2.5l3.6 2.6 4.4-.4 1.9 4 4 1.9-.4 4.4 2.6 3.6-2.6 3.6.4 4.4-4 1.9-1.9 4-4.4-.4L20 37.5l-3.6-2.6-4.4.4-1.9-4-4-1.9.4-4.4L3.9 21.4 6.5 17.8l-.4-4.4 4-1.9 1.9-4 4.4.4z"
    />
    <path d="M13.5 20.5l4.3 4.3 8.7-9.3" stroke="#fff" strokeWidth="3" fill="none" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
)

export const ChevronRight = (p: P) => (
  <svg {...base({ viewBox: '0 0 8 14', strokeWidth: 2, ...p })}>
    <path d="M1.5 1.5L6.5 7l-5 5.5" />
  </svg>
)

export const ChevronLeft = (p: P) => (
  <svg {...base({ viewBox: '0 0 12 20', strokeWidth: 2.6, ...p })}>
    <path d="M10 2L2 10l8 8" />
  </svg>
)

export const Disclosure = (p: P) => (
  <svg {...base({ viewBox: '0 0 12 12', strokeWidth: 2.2, ...p })}>
    <path d="M4 1.8L8.4 6 4 10.2" />
  </svg>
)

export const Moon = (p: P) => (
  <svg {...base(p)}>
    <path d="M20 14.5A8.5 8.5 0 1 1 9.5 4a7 7 0 0 0 10.5 10.5z" fill="currentColor" stroke="none" />
  </svg>
)

export const House = (p: P) => (
  <svg {...base(p)}>
    <path d="M3.5 11.2L12 4l8.5 7.2" />
    <path d="M5.8 9.6V19a1 1 0 0 0 1 1h3.7v-5.3h3v5.3h3.7a1 1 0 0 0 1-1V9.6" />
  </svg>
)

export const HouseFill = (p: P) => (
  <svg {...base(p)}>
    <path d="M3.5 11.2L12 4l8.5 7.2" />
    <path d="M5.8 9.6V19a1 1 0 0 0 1 1h3.7v-5.3h3v5.3h3.7a1 1 0 0 0 1-1V9.6L12 4.6z" fill="currentColor" />
  </svg>
)

export const Checklist = (p: P) => (
  <svg {...base(p)}>
    <path d="M3.8 6.2l1.6 1.6 2.8-3" />
    <path d="M3.8 12.7l1.6 1.6 2.8-3" />
    <path d="M3.8 19.2l1.6 1.6 2.8-3" />
    <path d="M11.5 6.5h8.7M11.5 13h8.7M11.5 19.5h8.7" />
  </svg>
)

export const Gear = (p: P) => (
  <svg {...base(p)}>
    <circle cx="12" cy="12" r="3.1" />
    <path d="M12 2.8l1.5 2.3 2.7-.6.9 2.6 2.6.9-.6 2.7 2.3 1.5-2.3 1.5.6 2.7-2.6.9-.9 2.6-2.7-.6L12 21.2l-1.5-2.3-2.7.6-.9-2.6-2.6-.9.6-2.7L2.8 12l2.3-1.5-.6-2.7 2.6-.9.9-2.6 2.7.6z" />
  </svg>
)

export const Wifi = (p: P) => (
  <svg {...base(p)}>
    <path d="M2.5 9a14 14 0 0 1 19 0" />
    <path d="M5.8 12.4a9.3 9.3 0 0 1 12.4 0" />
    <path d="M9.1 15.8a4.6 4.6 0 0 1 5.8 0" />
    <circle cx="12" cy="19.2" r="1.2" fill="currentColor" />
  </svg>
)

export const WifiSlash = (p: P) => (
  <svg {...base(p)}>
    <path d="M2.5 9a14 14 0 0 1 8.3-3.9" />
    <path d="M17.6 6.6A14 14 0 0 1 21.5 9" />
    <path d="M5.8 12.4a9.3 9.3 0 0 1 4-2.2" />
    <path d="M14.6 10.5a9.3 9.3 0 0 1 3.6 1.9" />
    <path d="M9.1 15.8a4.6 4.6 0 0 1 5.8 0" />
    <circle cx="12" cy="19.2" r="1.2" fill="currentColor" />
    <path d="M3.4 3.4l17.2 17.2" />
  </svg>
)

/** Two arrows chasing each other — spun by CSS while a round trip is in flight. */
export const ArrowsSync = (p: P) => (
  <svg {...base(p)}>
    <path d="M20.2 12a8.2 8.2 0 0 1-12.8 6.8" />
    <path d="M3.8 12A8.2 8.2 0 0 1 16.6 5.2" />
    <path d="M16.4 2.2v3.2h-3.2M7.6 21.8v-3.2h3.2" />
  </svg>
)

export const Folder = (p: P) => (
  <svg {...base(p)}>
    <path d="M3 7.5a2 2 0 0 1 2-2h4l2 2.2h8a2 2 0 0 1 2 2V17a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
  </svg>
)

export const Bell = (p: P) => (
  <svg {...base(p)}>
    <path d="M6 16.5V11a6 6 0 0 1 12 0v5.5l1.6 1.8H4.4z" />
    <path d="M10 20.5a2.2 2.2 0 0 0 4 0" />
  </svg>
)

export const Warning = (p: P) => (
  <svg {...base(p)}>
    <path d="M12 3.5l9.5 16.5h-19z" />
    <path d="M12 10v4.5" />
    <circle cx="12" cy="17.3" r="0.6" fill="currentColor" />
  </svg>
)

export const Pause = (p: P) => (
  <svg {...base(p)}>
    <circle cx="12" cy="12" r="9.2" />
    <path d="M10 8.8v6.4M14 8.8v6.4" />
  </svg>
)

export const Repeat = (p: P) => (
  <svg {...base(p)}>
    <path d="M4 11V9.5A3.5 3.5 0 0 1 7.5 6H19l-3-3M20 13v1.5a3.5 3.5 0 0 1-3.5 3.5H5l3 3" />
  </svg>
)

export const Person = (p: P) => (
  <svg {...base(p)}>
    <circle cx="12" cy="8.5" r="3.8" />
    <path d="M4.5 20.5a7.5 7.5 0 0 1 15 0" />
  </svg>
)

export const CalendarIcon = (p: P) => (
  <svg {...base(p)}>
    <rect x="3.5" y="5" width="17" height="15.5" rx="2.5" />
    <path d="M3.5 9.8h17M8 3v4M16 3v4" />
    <circle cx="8.2" cy="13.6" r="0.9" fill="currentColor" stroke="none" />
    <circle cx="12" cy="13.6" r="0.9" fill="currentColor" stroke="none" />
    <circle cx="15.8" cy="13.6" r="0.9" fill="currentColor" stroke="none" />
    <circle cx="8.2" cy="17" r="0.9" fill="currentColor" stroke="none" />
    <circle cx="12" cy="17" r="0.9" fill="currentColor" stroke="none" />
  </svg>
)

export const Plus = (p: P) => (
  <svg {...base(p)}>
    <path d="M12 5v14M5 12h14" />
  </svg>
)

export const Trash = (p: P) => (
  <svg {...base(p)}>
    <path d="M4.5 6.5h15M9.5 6.5V4.8c0-.7.6-1.3 1.3-1.3h2.4c.7 0 1.3.6 1.3 1.3v1.7M6.5 6.5l.8 12.2c.1 1 .9 1.8 1.9 1.8h5.6c1 0 1.8-.8 1.9-1.8l.8-12.2M10.2 10.5v6M13.8 10.5v6" />
  </svg>
)

export const Sliders = (p: P) => (
  <svg {...base(p)}>
    <path d="M4 7h9M17 7h3M4 17h3M11 17h9" />
    <circle cx="15" cy="7" r="2" />
    <circle cx="9" cy="17" r="2" />
  </svg>
)
