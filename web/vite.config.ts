import { defineConfig } from "vite";

// `npm run dev` proxies API and stream calls to a running openiptv-edge.
export default defineConfig({
  server: {
    proxy: {
      "/api": "http://127.0.0.1:8787",
      "/live": "http://127.0.0.1:8787",
    },
  },
  build: { target: "es2022" },
});
