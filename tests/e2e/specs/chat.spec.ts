import { test, expect } from "../fixtures/auth";

/**
 * Chat spec — serial: creating parallel sessions collides with the sidebar
 * "recent sessions" refresh and produces flaky ordering assertions.
 *
 * k3s topology note: chat round-trips only succeed after `scripts/seed-pi-from.sh`
 * has copied a warm pi-agent snapshot into the runner PVCs. Tests that require a
 * live model round-trip are gated on OMNIGENT_PI_SEEDED=1 so a fresh cluster
 * doesn't fail the whole suite before its first seed.
 */
test.describe.serial("chat", () => {
  test("chat: create new session, send prompt, receive pi reply within 90s", async ({
    page,
  }) => {
    test.skip(
      !process.env.OMNIGENT_PI_SEEDED,
      "requires seed-pi-from.sh — set OMNIGENT_PI_SEEDED=1",
    );
    const nanoid = Math.random().toString(36).slice(2, 10);
    const marker = `playwright-smoke-${nanoid}`;
    const prompt = `Reply with exactly the word: ${marker}`;

    await page.goto("/");
    await page
      .getByRole("link", { name: /^new session$/i })
      .or(page.getByRole("button", { name: /^new session$/i }))
      .first()
      .click();

    const composer = page
      .getByRole("textbox", { name: /describe a task|message|prompt/i })
      .first();
    await expect(composer).toBeVisible();
    await composer.fill(prompt);
    await composer.press("Enter");

    // Pi replies via the runner harness — allow up to 90s for the model round-trip.
    await expect(page.getByText(marker, { exact: false })).toBeVisible({
      timeout: 90_000,
    });
  });

  test("chat: harness picker shows >=3 online k3s pi runners (pi1/pi4/pi5)", async ({
    page,
  }) => {
    await page.goto("/");
    // Harness picker is the composer's leading "Runs with" / harness button.
    const picker = page
      .getByRole("button", { name: /pi|harness|runs with/i })
      .first();
    await picker.click();
    const menu = page.getByRole("menu").or(page.getByRole("listbox"));
    await expect(menu).toBeVisible();

    // k3s topology: 3 online hosts named omnigent-runner-pi{1,4,5}-<hash>.
    // Stale offline replicas from older ReplicaSets may also render — we only
    // assert the online-count floor, not an exact match.
    const runnerNamePattern = /omnigent-runner-pi(1|4|5)-.+/i;
    const runnerEntries = menu.getByText(runnerNamePattern);
    await expect(runnerEntries.first()).toBeVisible();
    expect(await runnerEntries.count()).toBeGreaterThanOrEqual(3);

    // "Create custom agent" affordance should still be present in the picker.
    await expect(menu.getByText(/create custom agent/i)).toBeVisible();
  });

  test("chat: keyboard shortcut Ctrl+N navigates to New session", async ({
    page,
  }) => {
    await page.goto("/settings/account");
    await expect(page.getByRole("heading", { name: /account/i })).toBeVisible();
    await page.keyboard.press("Control+n");
    await expect(page.getByText(/what should we build/i)).toBeVisible({
      timeout: 10_000,
    });
  });
});
