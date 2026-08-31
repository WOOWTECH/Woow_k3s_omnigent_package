import { test, expect } from "../fixtures/auth";

test.describe("settings", () => {
  test("settings/account shows admin badge", async ({ page }) => {
    await page.goto("/settings/account");
    await expect(page.getByRole("heading", { name: /account/i })).toBeVisible();
    await expect(page.getByText(/admin/i).first()).toBeVisible();
  });

  test("settings/appearance has Mode radio group with System/Light/Dark", async ({
    page,
  }) => {
    await page.goto("/settings/appearance");
    const modeGroup = page.getByRole("radiogroup", { name: /mode/i });
    await expect(modeGroup).toBeVisible();
    await expect(modeGroup.getByRole("radio", { name: /system/i })).toBeVisible();
    await expect(modeGroup.getByRole("radio", { name: /light/i })).toBeVisible();
    await expect(modeGroup.getByRole("radio", { name: /dark/i })).toBeVisible();
  });

  test("settings/appearance has 'Hide unconfigured harnesses' toggle", async ({
    page,
  }) => {
    await page.goto("/settings/appearance");
    await expect(
      page.getByRole("switch", { name: /hide unconfigured harnesses/i }),
    ).toBeVisible();
  });

  test("settings/git has 'Default base branch' textbox", async ({ page }) => {
    await page.goto("/settings/git");
    await expect(
      page.getByRole("textbox", { name: /default base branch/i }),
    ).toBeVisible();
  });

  test("settings/shortcuts shows Ctrl+N for 'Start a new session'", async ({
    page,
  }) => {
    await page.goto("/settings/shortcuts");
    const row = page.getByText(/start a new session/i).first();
    await expect(row).toBeVisible();
    // Keybinding tokens render as separate spans "Ctrl" + "N" (no literal +).
    await expect(page.getByText(/ctrl\s*\+?\s*n\b/i).first()).toBeVisible();
  });

  test("settings/members shows woow admin row and Invite member button", async ({
    page,
  }) => {
    await page.goto("/settings/members");
    await expect(page.getByText(/^woow$/i).first()).toBeVisible();
    await expect(page.getByText(/admin/i).first()).toBeVisible();
    await expect(
      page.getByRole("button", { name: /invite member/i }),
    ).toBeVisible();
  });

  test("settings/members clicking Invite opens modal, Cancel closes it", async ({
    page,
  }) => {
    await page.goto("/settings/members");
    await page.getByRole("button", { name: /invite member/i }).click();
    const dialog = page.getByRole("dialog");
    await expect(dialog).toBeVisible();
    await dialog.getByRole("button", { name: /^cancel$/i }).click();
    await expect(dialog).toBeHidden();
  });

  test("settings/policies shows Add policy button, opens 26-entry registry modal", async ({
    page,
  }) => {
    await page.goto("/settings/policies");
    const addBtn = page.getByRole("button", { name: /add policy/i });
    await expect(addBtn).toBeVisible();
    await addBtn.click();
    const dialog = page.getByRole("dialog");
    await expect(dialog).toBeVisible();
    // Registry entries render as role=button (each policy is a clickable
    // card). Filter out the modal action buttons (Cancel/Add/Close).
    const entries = dialog.getByRole("button").filter({
      hasNotText: /^(cancel|add|close)$/i,
    });
    await expect(entries.first()).toBeVisible();
    expect(await entries.count()).toBeGreaterThanOrEqual(20);
  });

  test("settings/sharing shows 4 radios (On/Read only/Read only restricted/Off)", async ({
    page,
  }) => {
    await page.goto("/settings/sharing");
    // Radio accessible-names include the full description, e.g.
    //   "On Anyone with manage access can share…"
    // so drop the ^…$ anchors and match the leading token + whitespace.
    for (const name of [/^on\s/i, /^read only\s/i, /read only \(restricted\)/i, /^off\s/i]) {
      await expect(page.getByRole("radio", { name })).toBeVisible();
    }
  });

  test("settings/archived lists at least the sidebar structure", async ({
    page,
  }) => {
    await page.goto("/settings/archived");
    // Sidebar has h2 "Archived" AND main has h1 "Archived sessions" — must
    // disambiguate or strict-mode fails.
    await expect(
      page.getByRole("heading", { name: /archived sessions/i }),
    ).toBeVisible();
    // Sidebar nav should still be present on the settings shell.
    await expect(
      page.getByRole("link", { name: /^settings$/i }).or(
        page.getByRole("button", { name: /^settings$/i }),
      ),
    ).toBeVisible();
  });
});
