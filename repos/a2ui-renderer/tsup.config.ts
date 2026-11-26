import { defineConfig } from 'tsup';

export default defineConfig({
  entry: ['src/index.tsx'],
  format: ['iife'],
  globalName: 'A2UIRenderer',
  outDir: 'dist',
  minify: true,
  bundle: true,
  sourcemap: true,
  clean: true,
  noExternal: [/.*/],
  define: {
    'process.env.NODE_ENV': '"production"',
  },
});
