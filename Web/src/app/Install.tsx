import { isStandalone } from '../core/push'

/** iPhone or iPad Safari (iPadOS reports itself as a Mac with touch). */
function isAppleMobile(): boolean {
  const ua = navigator.userAgent
  return /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)
}

const SKIP_KEY = 'upkeep.installSkipped'

/**
 * Upkeep only makes sense as a Home Screen app on iOS: that's where it works offline, keeps its
 * data and can get reminders — and iOS keeps its storage separate from Safari's. There's no install
 * button a page can trigger, so this shows the two taps instead. The icon it creates opens
 * https://upkeep-<person>.local:8443 (paired) without typing any address.
 */
export function shouldShowInstall(): boolean {
  if (isStandalone() || !isAppleMobile()) return false
  try {
    return sessionStorage.getItem(SKIP_KEY) !== '1'
  } catch {
    return true
  }
}

export function InstallScreen({ onSkip }: { onSkip: () => void }) {
  const skip = () => {
    try {
      sessionStorage.setItem(SKIP_KEY, '1')
    } catch {
      /* private mode */
    }
    onSkip()
  }
  return (
    <div className="onboarding install">
      <img className="app-icon" src="/icons/icon-180.png" alt="" />
      <h1>Add Upkeep to your Home Screen</h1>
      <p className="lede">Then open it from its icon — no address to type, it works offline and can remind you.</p>
      <ol className="install-steps">
        <li>
          <span className="step-number">1</span>
          <span className="grow">
            Tap <strong>Share</strong> <ShareGlyph /> in Safari’s toolbar
            <span className="hint">On iPhone it’s at the bottom; you may need to tap ••• first.</span>
          </span>
        </li>
        <li>
          <span className="step-number">2</span>
          <span className="grow">
            Choose <strong>Add to Home Screen</strong> <AddGlyph />
            <span className="hint">Keep “Open as Web App” on, then tap Add.</span>
          </span>
        </li>
        <li>
          <span className="step-number">3</span>
          <span className="grow">
            Open <strong>Upkeep</strong> from your Home Screen
            <span className="hint">You can close this Safari tab.</span>
          </span>
        </li>
      </ol>
      <div className="grow" />
      <div className="actions">
        <button className="button plain wide" onClick={skip}>
          Continue in Safari
        </button>
      </div>
    </div>
  )
}

function ShareGlyph() {
  return (
    <svg className="inline-glyph" viewBox="0 0 24 24" aria-label="Share" role="img">
      <path d="M12 3v12M8 7l4-4 4 4" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M7 10H6a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-7a2 2 0 0 0-2-2h-1" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
    </svg>
  )
}

function AddGlyph() {
  return (
    <svg className="inline-glyph" viewBox="0 0 24 24" aria-label="Add" role="img">
      <rect x="3.5" y="3.5" width="17" height="17" rx="4" fill="none" stroke="currentColor" strokeWidth="1.8" />
      <path d="M12 8v8M8 12h8" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
    </svg>
  )
}
