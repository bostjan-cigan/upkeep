import { describe, expect, it } from 'vitest'
import { base64UrlToBytes } from '../src/core/push'

describe('push', () => {
  it('decodes base64url VAPID keys without padding', () => {
    expect([...base64UrlToBytes('AQID_-8')]).toEqual([1, 2, 3, 255, 239])
    const key = 'BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U'
    const bytes = base64UrlToBytes(key)
    expect(bytes.length).toBe(65)
    expect(bytes[0]).toBe(4) // uncompressed P-256 point
  })
})
