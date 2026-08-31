import { test as base, expect, type Page } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

/**
 * Auth fixture — logs in once per worker, then hands every test an already
 * authenticated `page`. We stash `storageState` on disk (per-worker) so
 * repeated tests reuse the session cookie instead of hammering /login.
 *
 * Credentials default to the woow-openclaw dev box; override via env:
 *   OMNIGENT_ADMIN_USERNAME / OMNIGENT_ADMIN_PASSWORD.
 */

const USERNAME = process.env.OMNIGENT_ADMIN_USERNAME ?? "woow";
const PASSWORD = process.env.OMNIGENT_ADMIN_PASSWORD ?? "woowtech2026";

async function performLogin(page: Page): Promise<void> {
  await page.goto("/login");
  await page.getByLabel(/username/i).fill(USERNAME);
  await page.getByLabel(/password/i).fill(PASSWORD);
  await page.getByRole("button", { name: /sign in|log in|login/i }).click();
  // Home renders the "What should we build?" hero once auth completes.
  await expect(
    page.getByText(/what should we build/i),
  ).toBeVisible({ timeout: 20_000 });
}

type AuthFixtures = {
  storageStatePath: string;
  page: Page;
};

export const test = base.extend<{}, AuthFixtures>({
  storageStatePath: [
    async ({ browser }, use, workerInfo) => {
      const statePath = path.join(
        os.tmpdir(),
        `omnigent-e2e-storage-w${workerInfo.workerIndex}.json`,
      );
      if (!fs.existsSync(statePath)) {
        const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
        const page = await ctx.newPage();
        await performLogin(page);
        await ctx.storageState({ path: statePath });
        await ctx.close();
      }
      await use(statePath);
    },
    { scope: "worker" },
  ],

  page: async ({ browser, storageStatePath }, use) => {
    const ctx = await browser.newContext({
      storageState: storageStatePath,
      ignoreHTTPSErrors: true,
    });
    const page = await ctx.newPage();
    await use(page);
    await ctx.close();
  },
});

export { expect };
