import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  esbuild: {
    target: 'es2015'
  },
  // Use a frontend-only tsconfig to avoid backend type errors in dev
  optimizeDeps: {
    esbuildOptions: {
      tsconfig: 'tsconfig.frontend.json'
    }
  },
  server: {
    host: '0.0.0.0',
    port: 4000,
    strictPort: true,
    proxy: {
      '/api': {
        target: 'http://localhost:8788',
        changeOrigin: true
      },
      '/__proxy': {
        target: 'http://localhost:8788',
        changeOrigin: true
      },
      '/binance': {
        target: 'https://fapi.binance.com',
        changeOrigin: true,
        secure: true,
        rewrite: (path) => path.replace(/^\/binance/, '')
      }
    }
  },
  preview: {
    host: '0.0.0.0',
    port: 4000,
    strictPort: true,
    proxy: {
      '/api': {
        target: 'http://localhost:8788',
        changeOrigin: true
      },
      '/__proxy': {
        target: 'http://localhost:8788',
        changeOrigin: true
      },
      '/binance': {
        target: 'https://fapi.binance.com',
        changeOrigin: true,
        secure: true,
        rewrite: (path) => path.replace(/^\/binance/, '')
      }
    }
  }
});

