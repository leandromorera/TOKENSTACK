import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The bundle is committed and served by server.py, so no dev proxy is needed
// for the built artefact. `npm run dev` proxies /api to a server.py already
// running on 8799 so the UI can be iterated on without rebuilding.
export default defineConfig({
  plugins: [react()],
  build: { outDir: 'dist', emptyOutDir: true, sourcemap: false },
  server: { port: 5177, proxy: { '/api': 'http://127.0.0.1:8799' } },
})
