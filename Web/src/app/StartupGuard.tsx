import { Component, type ReactNode } from 'react'

declare global {
  interface Window {
    /** Set by the startup watchdog in index.html: reloads once, then explains and offers a reload. */
    upkeepStartupFailed?: (detail?: string) => void
  }
}

/**
 * Catches an error while rendering — the local database failing to open lands here too — and
 * hands it to the watchdog in index.html instead of leaving a blank screen.
 */
export class StartupGuard extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false }

  static getDerivedStateFromError(): { failed: boolean } {
    return { failed: true }
  }

  componentDidCatch(error: unknown): void {
    window.upkeepStartupFailed?.(error instanceof Error ? error.message : String(error))
  }

  render(): ReactNode {
    return this.state.failed ? null : this.props.children
  }
}
