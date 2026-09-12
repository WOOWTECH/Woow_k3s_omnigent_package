import { test as base, expect, type Page } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

/**
 * Auth fixture — logs in once per worker, then hands every test an already
 * authenticated `page`. We stash `storageState` on disk (per-worker) so
 * repeated tests reuse the session cookie instead of hammering /login.
 *
 * Credentials come from the environment only — there is deliberately no
 * fallback. The values that used to sit here were the ones the production
 * deployment actually uses, in a public repo. Export them from the cluster
 * Secret before running:
 *   export OMNIGENT_ADMIN_USERNAME=$(kubectl -n omnigent get secret omnigent-admin \
 *     -o go-template='{{index .data "OMNIGENT_ADMIN_USERNAME" | base64decode}}')
 *   export OMNIGENT_ADMIN_PASSWORD=$(kubectl -n omnigent get secret omnigent-admin \
 *     -o go-template='{{index .data "OMNIGENT_ADMIN_PASSWORD" | base64decode}}')
 */

function required(name: string): string {
  const v = process.env[name];
  if (!v) {
    throw new Error(
      `${name} is not set — export the admin credentials from the omnigent-admin Secret (see tests/e2e/README.md)`,
    );
  }
  return v;
}

const USERNAME = required("OMNIGENT_ADMIN_USERNAME");
const PASSWORD = required("OMNIGENT_ADMIN_PASSWORD");

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
