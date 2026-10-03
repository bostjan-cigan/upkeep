// Picking up the pairing token from the address (src/core/sync.ts › consumePairingFragment): a
// QR code just scanned pairs, the Home Screen icon's start URL only fills in a missing pairing.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { getMeta, resetDatabase, setMeta } from '../src/core/db'
import { consumePairingFragment } from '../src/core/sync'

/** Opens the app at `url`, as the Home Screen app or a Safari tab. */
function openAt(url: string, standalone: boolean) {
  const { hash, search, pathname } = new URL(url, 'https://upkeep-ana.local')
  vi.stubGlobal('location', { hash, search, pathname })
  vi.stubGlobal('history', { replaceState: vi.fn() })
  vi.stubGlobal('navigator', { standalone })
  const manifest = { rel: 'manifest', href: '/manifest.webmanifest' }
  vi.stubGlobal('document', { querySelector: () => manifest, createElement: () => manifest, head: { appendChild: vi.fn() } })
  return manifest
}

beforeEach(async () => {
  await resetDatabase()
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('consumePairingFragment', () => {
  it('keeps a newer pairing when the icon opens with the token it was installed with', async () => {
    await setMeta('pairToken', 'FROM-CODE')
    openAt('/?pair=FROM-OLD-QR', true)
    expect(await consumePairingFragment()).toBe(true)
    expect(await getMeta('pairToken')).toBe('FROM-CODE')
  })

  it('pairs the icon from its start URL when it has no pairing yet', async () => {
    openAt('/?pair=FROM-QR', true)
    expect(await consumePairingFragment()).toBe(true)
    expect(await getMeta('pairToken')).toBe('FROM-QR')
  })

  it('pairs again from a QR code just scanned, and installs with that token', async () => {
    await setMeta('pairToken', 'OLD')
    const manifest = openAt('/#pair=NEW', false)
    expect(await consumePairingFragment()).toBe(true)
    expect(await getMeta('pairToken')).toBe('NEW')
    expect(manifest.href).toBe('/manifest.webmanifest?pair=NEW')
  })

  it('points a reloaded Safari tab’s icon at the pairing it has, not the one in its address', async () => {
    await setMeta('pairToken', 'CURRENT')
    const manifest = openAt('/?pair=STALE', false)
    await consumePairingFragment()
    expect(manifest.href).toBe('/manifest.webmanifest?pair=CURRENT')
  })

  it('does nothing without a token in the address', async () => {
    await setMeta('pairToken', 'T')
    openAt('/', true)
    expect(await consumePairingFragment()).toBe(false)
    expect(await getMeta('pairToken')).toBe('T')
  })
})
