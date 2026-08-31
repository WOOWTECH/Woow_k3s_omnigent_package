import { test, expect } from "../fixtures/auth";

/**
 * k3s-hosts spec — asserts the k3s Deployment topology: 3 online runner Pods
 * named omnigent-runner-pi{1,4,5}-<hash>. Stale offline entries from prior
 * ReplicaSets are allowed and ignored; we only enforce the online-count floor.
 *
 * Uses the authenticated `page` fixture so `page.request` reuses the login
 * cookie for /v1/hosts (which requires auth).
 */
test.describe("k3s hosts", () => {
  test("/v1/hosts returns >=3 online runners matching omnigent-runner-pi(1|4|5)-*", async ({
    page,
  }) => {
    const res = await page.request.get("/v1/hosts");
    expect(res.status()).toBe(200);
    const body = await res.json();

    // Endpoint may return either a bare array or {hosts:[...]} — accept both.
    const hosts: Array<Record<string, unknown>> = Array.isArray(body)
      ? body
      : Array.isArray((body as { hosts?: unknown[] }).hosts)
        ? ((body as { hosts: Array<Record<string, unknown>> }).hosts)
        : [];
    expect(hosts.length).toBeGreaterThan(0);

    const namePattern = /^omnigent-runner-pi(1|4|5)-.+/;
    const isOnline = (h: Record<string, unknown>): boolean => {
      const status = String(
        h.status ?? h.state ?? h.health ?? "",
      ).toLowerCase();
      if (h.online === true) return true;
      if (status && /^(online|ready|healthy|running|connected)$/.test(status)) {
        return true;
      }
      return false;
    };
    const nameOf = (h: Record<string, unknown>): string =>
      String(h.name ?? h.hostname ?? h.id ?? "");

    const onlineK3sRunners = hosts.filter(
      (h) => namePattern.test(nameOf(h)) && isOnline(h),
    );

    expect(onlineK3sRunners.length).toBeGreaterThanOrEqual(3);

    // Sanity: at least one instance of each of pi1/pi4/pi5 is present online.
    for (const tag of ["pi1", "pi4", "pi5"]) {
      const perTag = onlineK3sRunners.filter((h) =>
        new RegExp(`^omnigent-runner-${tag}-.+`).test(nameOf(h)),
      );
      expect(perTag.length, `expected an online ${tag} runner`).toBeGreaterThanOrEqual(1);
    }
  });
});
