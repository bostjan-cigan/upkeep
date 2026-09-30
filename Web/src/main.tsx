import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
// Modules register their record kinds on import.
import './modules/maintenance'
import { App } from './app/App'
import { StartupGuard } from './app/StartupGuard'
// Sets <html data-appearance> at import time, before anything renders.
import './app/appearanceStore'
import './app/styles.css'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <StartupGuard>
      <App />
    </StartupGuard>
  </StrictMode>,
)
