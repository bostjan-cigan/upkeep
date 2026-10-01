import { useState } from 'react'
import { pairWithCode } from '../core/sync'

/** Type the code the Mac shows under Settings › Phones › Pair a Phone… */
export function PairCodeEntry({ onPaired }: { onPaired?: () => void }) {
  const [code, setCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const submit = async () => {
    setBusy(true)
    setError(null)
    const problem = await pairWithCode(code)
    setBusy(false)
    if (problem) setError(problem)
    else {
      setCode('')
      onPaired?.()
    }
  }

  return (
    <form
      className="pair-code"
      onSubmit={(e) => {
        e.preventDefault()
        if (!busy) void submit()
      }}
    >
      <div className="pair-code-row">
        <input
          className="field pair-code-input"
          value={code}
          onChange={(e) => setCode(e.target.value.toUpperCase())}
          placeholder="XXXX-XXXX"
          aria-label="Pairing code"
          autoCapitalize="characters"
          autoComplete="one-time-code"
          autoCorrect="off"
          spellCheck={false}
          maxLength={12}
          enterKeyHint="go"
        />
        <button className="button primary" type="submit" disabled={busy || code.replace(/[^A-Za-z0-9]/g, '').length < 8}>
          {busy ? 'Pairing…' : 'Pair'}
        </button>
      </div>
      {error && <p className="pair-code-error">{error}</p>}
    </form>
  )
}
