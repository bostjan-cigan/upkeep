// Hybrid logical clock (Docs/Sync.md › Clock).
import type { Millis } from './dates'

/** `t = max(now, maxSeen + 1 ms)`. The caller persists `t` as the new maxSeen. */
export function nextStamp(now: Millis, maxSeen: Millis): Millis {
  const floor = Number.isFinite(maxSeen) ? maxSeen + 1 : Number.NEGATIVE_INFINITY
  return Math.max(Math.round(now), floor)
}

/** In-memory clock; `db.ts` wraps the same logic around the persisted `maxSeen`. */
export class HybridClock {
  constructor(public maxSeen: Millis = 0, private readonly now: () => Millis = Date.now) {}

  /** A stamp for a local change, strictly greater than everything seen so far. */
  stamp(): Millis {
    const t = nextStamp(this.now(), this.maxSeen)
    this.maxSeen = t
    return t
  }

  /** Records a stamp from merged data. */
  observe(stamp: Millis): void {
    if (Number.isFinite(stamp) && stamp > this.maxSeen) this.maxSeen = stamp
  }
}
