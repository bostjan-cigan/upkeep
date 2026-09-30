// This build's stamp, sent as `device.build` in snapshots. Kept apart from `pwa.ts` so the
// service worker can import it without dragging the DOM in (see sw.ts).

declare const __BUILD_DATE__: string
declare const __BUILD_HASH__: string

export const BUILD_DATE: string = typeof __BUILD_DATE__ === 'string' ? __BUILD_DATE__ : 'dev'
export const BUILD_HASH: string = typeof __BUILD_HASH__ === 'string' ? __BUILD_HASH__ : 'dev'
export const APP_VERSION = '1.0'
export const BUILD_STAMP = `${APP_VERSION} (${BUILD_DATE.replaceAll('-', '')}.${BUILD_HASH})`
