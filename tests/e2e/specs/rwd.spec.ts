import { test, expect } from "../fixtures/auth";

test.describe("responsive layout", () => {
  test("mobile 375x812: sidebar collapses to hamburger", async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 812 });
    await page.goto("/");
    // On mobile the primary nav is behind a hamburger toggle; the persistent
    // sidebar's nav links should NOT be visible until it is opened.
    const hamburger = page
      .getByRole("button", { name: /menu|open sidebar|navigation/i })
      .first();
    await expect(hamburger).toBeVisible();
    // Sidebar-only "Automations" link should be hidden in the collapsed state.
    await expect(
      page.getByRole("link", { name: /^automations$/i }),
    ).toBeHidden();
  });

  test("desktop 1440x900: sidebar visible + workspace panel visible", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto("/");
    await expect(
      page
        .getByRole("link", { name: /^new session$/i })
        .or(page.getByRole("button", { name: /^new session$/i })),
    ).toBeVisible();
    await expect(
      page.getByRole("link", { name: /^automations$/i }),
    ).toBeVisible();
    // Workspace / composer panel visible on the right of the shell.
    await expect(page.getByText(/what should we build/i)).toBeVisible();
  });
});
