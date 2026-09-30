/// <reference types="vitest/config" />
import { createHash } from 'node:crypto'
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'
import { VitePWA } from 'vite-plugin-pwa'

const here = import.meta.dirname

/** Short hash of everything that goes into the bundle, so two builds of the same sources match. */
function contentHash(): string {
  const hash = createHash('sha256')
  const roots = [join(here, 'src'), join(here, 'public'), join(here, 'index.html'), join(here, '..', 'Upkeep', 'Icons')]
  const walk = (path: string) => {
    if (statSync(path).isDirectory()) {
      for (const name of readdirSync(path).sort()) walk(join(path, name))
    } else {
      hash.update(relative(here, path))
      hash.update(readFileSync(path))
    }
  }
  roots.forEach(walk)
  return hash.digest('hex').slice(0, 7)
}

const buildDate = new Date().toISOString().slice(0, 10)

export default defineConfig({
  base: '/',
  define: {
    __BUILD_DATE__: JSON.stringify(buildDate),
    __BUILD_HASH__: JSON.stringify(contentHash()),
  },
  server: {
    // The item icons live in the Mac app's folder so both apps share one set.
    fs: { allow: ['..'] },
  },
  build: {
    target: 'es2022',
    assetsInlineLimit: 0,
  },
  plugins: [
    react(),
    VitePWA({
      registerType: 'prompt',
      injectRegister: false,
      strategies: 'injectManifest',
      srcDir: 'src',
      filename: 'sw.ts',
      includeAssets: ['icons/*.png'],
      manifest: {
        name: 'Upkeep',
        short_name: 'Upkeep',
        description: 'Routine home maintenance for the whole household.',
        // A stable id, so the personalised start URL (`/?pair=…`) is still the same app.
        id: '/',
        start_url: '/',
        scope: '/',
        display: 'standalone',
        orientation: 'any',
        theme_color: '#F2F2F7',
        background_color: '#F2F2F7',
        icons: [
          { src: '/icons/icon-192.png', sizes: '192x192', type: 'image/png' },
          { src: '/icons/icon-512.png', sizes: '512x512', type: 'image/png' },
          { src: '/icons/icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
        ],
      },
      injectManifest: {
        globPatterns: ['**/*.{js,css,html,svg,png,ico,webmanifest}'],
      },
      devOptions: { enabled: false },
    }),
  ],
  test: {
    environment: 'node',
    include: ['test/**/*.test.ts'],
    setupFiles: ['test/setup.ts'],
    env: { TZ: 'Europe/Ljubljana' },
  },
})
