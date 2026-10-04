import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The browser talks to /api; Vite proxies it to PostgREST, so there's no CORS setup.
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      '/api': {
        target: `http://127.0.0.1:${process.env.API_PORT ?? 3000}`,
        rewrite: (path) => path.replace(/^\/api/, ''),
      },
    },
  },
  test: {
    environment: 'jsdom',
  },
});
