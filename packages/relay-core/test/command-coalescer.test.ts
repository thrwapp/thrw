import { describe, expect, it } from "vitest";

import {
  CommandCoalescer,
  DEFAULT_CLAIM_WINDOW_MS,
  DEFAULT_RELEASE_WINDOW_MS,
  type CoalescedCommand,
  type CommandKind,
  type Scheduler,
} from "../src/index.js";

// ADR 0020 decision 1 (#277). The behaviour under test is entirely about
// *timing*, so a fake clock and a fake scheduler are the whole harness - no
// broker, no waiting on wall time.
class FakeScheduler implements Scheduler {
  private nextId = 1;
  private readonly timers = new Map<number, { callback: () => void; dueAt: number }>();
  now = 0;

  setTimeout(callback: () => void, ms: number): unknown {
    const id = this.nextId++;
    this.timers.set(id, { callback, dueAt: this.now + ms });
    return id;
  }

  clearTimeout(handle: unknown): void {
    this.timers.delete(handle as number);
  }

  pendingCount(): number {
    return this.timers.size;
  }

  /** Advances the clock, firing anything that comes due on the way. */
  advance(ms: number): void {
    const target = this.now + ms;
    for (;;) {
      const due = [...this.timers.entries()]
        .filter(([, timer]) => timer.dueAt <= target)
        .sort((a, b) => a[1].dueAt - b[1].dueAt)[0];
      if (!due) break;
      const [id, timer] = due;
      this.timers.delete(id);
      this.now = timer.dueAt;
      timer.callback();
    }
    this.now = target;
  }
}

const ACCOUNT = "tom-personal";
const NODE_A = "aaaaaaaa-0000-0000-0000-000000000001";
const NODE_B = "bbbbbbbb-0000-0000-0000-000000000002";
const AUDIO = "audio";

interface Harness {
  readonly coalescer: CommandCoalescer;
  readonly scheduler: FakeScheduler;
  readonly dispatched: string[];
  readonly coalesced: CoalescedCommand[];
}

function harness(): Harness {
  const scheduler = new FakeScheduler();
  const dispatched: string[] = [];
  const coalesced: CoalescedCommand[] = [];
  const coalescer = new CommandCoalescer({
    dispatch: (_account, node, _resource, kind: CommandKind) =>
      dispatched.push(`${node === NODE_A ? "A" : "B"}:${kind}`),
    onCoalesced: (c) => coalesced.push(c),
    now: () => scheduler.now,
    scheduler,
  });
  return { coalescer, scheduler, dispatched, coalesced };
}

describe("CommandCoalescer (ADR 0020 decision 1)", () => {
  // The constraint that matters most: if every switch paid the window, this
  // would have made the product slower to fix a case that happens rarely.
  it("dispatches a single trigger immediately, paying nothing", () => {
    const { coalescer, dispatched, scheduler } = harness();

    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim");

    expect(dispatched).toEqual(["A:claim"]);
    // No timer at all: nothing is waiting to happen later.
    expect(scheduler.pendingCount()).toBe(0);
  });

  it("dispatches immediately again once the window has fully elapsed", () => {
    const { coalescer, dispatched, scheduler } = harness();

    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim");
    scheduler.advance(DEFAULT_CLAIM_WINDOW_MS);
    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "release");

    expect(dispatched).toEqual(["A:claim", "A:release"]);
  });

  // The regression that redesigned this. ADR 0002 handoff is sequential: the
  // winner cannot take the route until the loser lets go, so a held release
  // does not damp a burst, it stalls the switch and the claim behind it.
  it("never holds a release, because the handoff waits behind it", () => {
    const { coalescer, dispatched, scheduler } = harness();

    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim");
    scheduler.advance(100); // a second device wants it, 100ms later
    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "release");

    // Immediately, not in 6s. Coalescing both directions turned a ~4.9s switch
    // into a ~11s one and failed relay-hosted's real-broker handoff test.
    expect(dispatched).toEqual(["A:claim", "A:release"]);
  });

  it("collapses repeated claims to one per window", () => {
    const { coalescer, dispatched, coalesced, scheduler } = harness();

    // The thrash that matters: a node told to claim over and over while the
    // route is still settling. The claim is the slow, contended operation.
    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim");
    for (const step of [500, 500, 500]) {
      scheduler.advance(step);
      coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim");
    }

    expect(dispatched).toEqual(["A:claim"]);
    scheduler.advance(DEFAULT_CLAIM_WINDOW_MS);

    // Collapsed to nothing extra: the node was told to claim and still should
    // be, so there is nothing left to send.
    expect(dispatched).toEqual(["A:claim"]);
    expect(coalesced.map((c) => c.reason)).toEqual([
      "superseded_by_newer_command",
      "superseded_by_newer_command",
      "already_in_target_state",
    ]);
  });

  it("dispatches a claim held behind a release once its window closes", () => {
    const { coalescer, dispatched, scheduler } = harness();

    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "release");
    scheduler.advance(100);
    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim"); // bounced straight back

    // Held: the device is still settling the release it was just given.
    expect(dispatched).toEqual(["A:release"]);
    scheduler.advance(DEFAULT_RELEASE_WINDOW_MS);
    expect(dispatched).toEqual(["A:release", "A:claim"]);
  });

  it("lets a release cancel a claim that is still queued", () => {
    const { coalescer, dispatched, coalesced, scheduler } = harness();

    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim");
    scheduler.advance(100);
    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim"); // queued
    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "release"); // newer intent wins

    expect(dispatched).toEqual(["A:claim", "A:release"]);
    expect(coalesced.at(-1)).toMatchObject({
      dropped: "claim",
      reason: "superseded_by_newer_command",
    });
    // And the cancelled claim must not resurface later and undo the release.
    scheduler.advance(DEFAULT_CLAIM_WINDOW_MS * 2);
    expect(dispatched).toEqual(["A:claim", "A:release"]);
  });

  // The asymmetry is the whole subtlety of the ADR's amendment, probed with a
  // claim on both sides since a release is never held.
  it("uses the longer window after a claim than after a release", () => {
    const afterClaim = harness();
    afterClaim.coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim");
    afterClaim.scheduler.advance(DEFAULT_RELEASE_WINDOW_MS + 1);
    afterClaim.coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim");
    // Past the release window but still inside the claim window, so it waits:
    // a claim takes ~4.9s to settle (#254), not ~2.2s.
    expect(afterClaim.dispatched).toEqual(["A:claim"]);

    const afterRelease = harness();
    afterRelease.coalescer.submit(ACCOUNT, NODE_A, AUDIO, "release");
    afterRelease.scheduler.advance(DEFAULT_RELEASE_WINDOW_MS + 1);
    afterRelease.coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim");
    // Same elapsed time, but a release settles in ~2.2s, so this goes now.
    expect(afterRelease.dispatched).toEqual(["A:release", "A:claim"]);
  });

  it("asserts the window figures the measurements justify", () => {
    // Not a tautology: these two constants are the part of this change a
    // reviewer cannot check by reading the code, so the numbers from
    // docs/handoffs/254.md are pinned here next to what they cover.
    expect(DEFAULT_RELEASE_WINDOW_MS).toBeGreaterThan(2_200); // measured Mac release
    expect(DEFAULT_CLAIM_WINDOW_MS).toBeGreaterThan(4_900); // measured Pixel claim
    expect(DEFAULT_CLAIM_WINDOW_MS).toBeGreaterThan(DEFAULT_RELEASE_WINDOW_MS);
  });

  it("keys on (account, node, resource) so nodes do not block each other", () => {
    const { coalescer, dispatched, scheduler } = harness();

    // The normal handoff: release the old holder, claim the new one, at once.
    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "release");
    coalescer.submit(ACCOUNT, NODE_B, AUDIO, "claim");
    expect(dispatched).toEqual(["A:release", "B:claim"]);

    // A's window must not suppress B's, or the second half of every handoff
    // would be held behind the first. Probed with a claim, which is the kind
    // that can be held at all.
    scheduler.advance(100);
    coalescer.submit(ACCOUNT, NODE_B, AUDIO, "claim");
    expect(dispatched).toEqual(["A:release", "B:claim"]);
    scheduler.advance(DEFAULT_CLAIM_WINDOW_MS);
    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim");
    expect(dispatched).toEqual(["A:release", "B:claim", "A:claim"]);
  });

  it("does not coalesce the same resource across different accounts", () => {
    const { coalescer, dispatched, scheduler } = harness();
    coalescer.submit("account-one", NODE_A, AUDIO, "claim");
    scheduler.advance(100);
    coalescer.submit("account-two", NODE_A, AUDIO, "claim");
    expect(dispatched).toEqual(["A:claim", "A:claim"]);
  });

  // The hazard that makes dispatchImmediately exist rather than being a
  // convenience: a restarted node has lost its own state, so a re-assert must
  // never be coalesced away as "already in target state".
  it("never suppresses a re-assert to a node that just restarted", () => {
    const { coalescer, dispatched, scheduler } = harness();

    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim");
    scheduler.advance(200); // the node restarts and re-registers, inside the window
    coalescer.dispatchImmediately(ACCOUNT, NODE_A, AUDIO, "claim");

    expect(dispatched).toEqual(["A:claim", "A:claim"]);
  });

  it("drops a queued transition when a re-assert overtakes it", () => {
    const { coalescer, dispatched, coalesced, scheduler } = harness();

    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim");
    scheduler.advance(200);
    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim"); // queued
    coalescer.dispatchImmediately(ACCOUNT, NODE_A, AUDIO, "claim");

    expect(dispatched).toEqual(["A:claim", "A:claim"]);
    expect(coalesced.at(-1)).toMatchObject({
      dropped: "claim",
      reason: "superseded_by_newer_command",
    });
    // The queued claim must not arrive later as a third dispatch.
    scheduler.advance(DEFAULT_CLAIM_WINDOW_MS * 2);
    expect(dispatched).toEqual(["A:claim", "A:claim"]);
  });

  it("restarts the window from the re-assert, not from the original dispatch", () => {
    const { coalescer, dispatched, scheduler } = harness();
    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim");
    scheduler.advance(DEFAULT_CLAIM_WINDOW_MS - 100);
    coalescer.dispatchImmediately(ACCOUNT, NODE_A, AUDIO, "claim");
    scheduler.advance(200); // past the *original* window, inside the new one
    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim");
    expect(dispatched).toEqual(["A:claim", "A:claim"]);
  });

  it("drops pending commands on stop rather than publishing after shutdown", () => {
    const { coalescer, dispatched, scheduler } = harness();

    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim");
    scheduler.advance(100);
    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim");
    coalescer.stop();
    scheduler.advance(DEFAULT_CLAIM_WINDOW_MS * 2);

    expect(dispatched).toEqual(["A:claim"]);
    expect(scheduler.pendingCount()).toBe(0);
  });

  it("holds only one timer per key however long the burst runs", () => {
    const { coalescer, scheduler } = harness();
    coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim");
    for (let i = 0; i < 10; i++) {
      scheduler.advance(100);
      coalescer.submit(ACCOUNT, NODE_A, AUDIO, "claim");
    }
    expect(scheduler.pendingCount()).toBe(1);
  });
});
