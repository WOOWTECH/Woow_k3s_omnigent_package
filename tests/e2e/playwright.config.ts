import { defineConfig, devices } from "@playwright/test";

/**
 * Playwright config for Omnigent 0.11.0 Web UI E2E suite — k3s topology.
 *
 * - Chromium-only so the same suite runs on arm64/amd64 CI (Woow_k3s runners).
 * - `baseURL` comes from OMNIGENT_BASE_URL; falls back to the cloudflared
 *   public URL fronting the k3s Service.
 * - `ignoreHTTPSErrors: true` — cloudflared serves a real cert but leaving this
 *   on prevents surprise flakes when CI resolves the host with a stale root.
 * - Serialized (workers: 1) so chat-session tests don't race the sidebar session list.
 */
const BASE_URL =
  process.env.OMNIGENT_BASE_URL ?? "https://omnigent.woowtech.io";

export default defineConfig({
  testDir: "./specs",
  timeout: 60_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [["list"], ["html", { open: "never" }]] : "list",
  use: {
    baseURL: BASE_URL,
    ignoreHTTPSErrors: true,
    trace: "on-first-retry",
    video: "off",
    screenshot: "only-on-failure",
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
