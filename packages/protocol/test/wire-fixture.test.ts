import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  COMMAND_OUTCOME_KIND,
  COMMAND_OUTCOME_TIMEOUT_MS,
  PRIORITY_ORDER,
  RESOURCE_AUDIO,
  type CommandFailureReason,
  type CommandOutcome,
  type CommandOutcomePayload,
  type EventKind,
  type ResourceType,
} from "../src/index.js";

/**
 * The shared **payload** contract, asserted against
 * `fixtures/wire.json` (#317).
 *
 * Sibling to `topics-fixture.test.ts`, which does this for topic strings
 * (#171). Swift asserts the same file in `adapter-mac`'s
 * `WireFixtureTests`, Kotlin in `adapter-android`'s `WireFixtureTest`.
 *
 * This file covers the half `packages/protocol` actually declares: the
 * shared constants, the closed vocabularies, the `kind` discriminators
 * and `CommandOutcomePayload`. `EventPayload`, `CommandPayload`,
 * `SequencedCommandPayload` and `StatePayload` live in
 * `packages/relay-core` and are asserted by that package's own
 * `wire-fixture.test.ts` — one fixture, asserted by whoever declares
 * each piece, rather than a second copy here.
 *
 * ## Why every assertion below is a runtime one
 *
 * Both tsconfigs are `"include": ["src"]`, so `pnpm turbo typecheck`
 * never sees this file and Vitest transpiles without checking types. A
 * `satisfies` clause here would look like a conformance assertion and be
 * checked by nothing. So the fixture is validated by reading it, not by
 * typing it.
 */

interface WireFixture {
  constants: {
    commandOutcomeTimeoutMs: number;
    heartbeatIntervalMs: number;
    heartbeatTimeoutMs: number;
  };
  vocabularies: {
    eventKinds: EventKind[];
    commandTypes: string[];
    resourceTypes: ResourceType[];
    platforms: string[];
    outcomes: CommandOutcome[];
    failureReasons: CommandFailureReason[];
  };
  kinds: { register: string; eventEnd: string; commandOutcome: string };
  directions: { nodeToRelay: string[]; relayToNode: string[] };
  messages: Record<string, Record<string, unknown>>;
}

const fixture = JSON.parse(
  readFileSync(new URL("../fixtures/wire.json", import.meta.url), "utf8"),
) as WireFixture;

/**
 * The fixture carries `$comment` keys for the reader. They are
 * documentation, not payload, and must not be mistaken for wire fields —
 * so every message-shape assertion strips them first.
 */
function wire(name: string): Record<string, unknown> {
  const message = fixture.messages[name];
  expect(message, `fixture has no message named ${name}`).toBeDefined();
  const { $comment: _dropped, ...rest } = message;
  return rest;
}

describe("shared constants match the cross-platform fixture", () => {
  /**
   * The one number #206 criterion 2 is explicit about: an adapter that
   * picked its own bound would silently make the aggregate switch
   * success rate meaningless, because an outcome would not mean the same
   * thing in every row.
   */
  it("pins the command outcome bound", () => {
    expect(COMMAND_OUTCOME_TIMEOUT_MS).toBe(fixture.constants.commandOutcomeTimeoutMs);
  });

  /**
   * `heartbeatIntervalMs` and `heartbeatTimeoutMs` are deliberately not
   * asserted here: `packages/protocol` declares neither. The interval is
   * an adapter constant (`defaultHeartbeatInterval` in Swift,
   * `DEFAULT_INTERVAL_MS` in Kotlin) and the timeout is the relay's
   * (`DEFAULT_HEARTBEAT_TIMEOUT_MS`, module-local in
   * `relay-service.ts`). Each is asserted by the implementation that
   * declares it; the fixture is what makes them one number rather than
   * three.
   *
   * What *is* assertable here is the relationship between them, which is
   * the part a future edit is most likely to break silently.
   */
  it("keeps the relay's timeout an exact multiple of the beat interval", () => {
    const { heartbeatIntervalMs, heartbeatTimeoutMs } = fixture.constants;
    expect(heartbeatTimeoutMs % heartbeatIntervalMs).toBe(0);
    expect(heartbeatTimeoutMs / heartbeatIntervalMs).toBe(3);
  });
});

/**
 * The fixture has to be internally consistent, or a platform test can
 * pass by quietly not covering a message. These are assertions about the
 * file rather than about any implementation, and they belong here
 * because this is the package that owns it.
 */
describe("the fixture is internally consistent", () => {
  it("assigns every message exactly one direction", () => {
    const { nodeToRelay, relayToNode } = fixture.directions;
    const directed = [...nodeToRelay, ...relayToNode].sort();
    const declared = Object.keys(fixture.messages)
      .filter((key) => key !== "$comment")
      .sort();

    expect(directed).toEqual(declared);
    expect(new Set(directed).size).toBe(directed.length);
  });

  it("names no message it does not define", () => {
    for (const name of [
      ...fixture.directions.nodeToRelay,
      ...fixture.directions.relayToNode,
    ]) {
      expect(fixture.messages[name], `${name} is directed but undefined`).toBeDefined();
    }
  });
});

describe("closed vocabularies match the cross-platform fixture", () => {
  /**
   * Order is load-bearing here, unlike every other vocabulary in the
   * fixture: this is architecture.md's priority ranking, highest first.
   * `toEqual` on the array rather than a set comparison is the point.
   */
  it("pins the event kinds in priority order", () => {
    expect(PRIORITY_ORDER).toEqual(fixture.vocabularies.eventKinds);
  });

  it("pins the audio resource type", () => {
    expect(RESOURCE_AUDIO).toBe("audio");
    expect(fixture.vocabularies.resourceTypes).toContain(RESOURCE_AUDIO);
  });

  it("pins the command outcome kind discriminator", () => {
    expect(COMMAND_OUTCOME_KIND).toBe(fixture.kinds.commandOutcome);
  });

  /**
   * Wire spelling, not identifier spelling. Swift's case is `timedOut`
   * and Kotlin's is `TIMED_OUT`; both serialise to `timed_out`, and a
   * mirror that shipped the identifier instead would be accepted by
   * nothing and rejected silently.
   */
  it("uses snake_case wire spellings throughout", () => {
    expect(fixture.vocabularies.outcomes).toContain("timed_out");
    expect(fixture.vocabularies.eventKinds).toContain("manual_claim");
    expect(fixture.vocabularies.failureReasons).toEqual([
      "bluetooth_unavailable",
      "target_device_unreachable",
      "superseded_by_newer_command",
    ]);
    expect(fixture.kinds.eventEnd).toBe("event_end");
  });
});

describe("CommandOutcomePayload round-trips every fixture message", () => {
  const outcomeMessages = [
    "commandOutcomeSucceeded",
    "commandOutcomeFailed",
    "commandOutcomeSuperseded",
    "commandOutcomeTimedOut",
    "commandOutcomeUnsequenced",
  ];

  /**
   * Rebuilding the payload field by field through the declared type and
   * then deep-comparing proves the TypeScript shape can represent the
   * wire object *exactly* — no field the type cannot carry, and none it
   * adds. A `JSON.parse(...) as CommandOutcomePayload` cast would assert
   * nothing at all, since the cast is erased.
   */
  it.each(outcomeMessages)("represents %s without loss", (name) => {
    const raw = wire(name);

    const rebuilt: CommandOutcomePayload = {
      kind: "command_outcome",
      resourceType: raw.resourceType as ResourceType,
      outcome: raw.outcome as CommandOutcome,
      durationMs: raw.durationMs as number,
      ...(raw.epoch !== undefined ? { epoch: raw.epoch as string } : {}),
      ...(raw.seq !== undefined ? { seq: raw.seq as number } : {}),
      ...(raw.reason !== undefined
        ? { reason: raw.reason as CommandFailureReason }
        : {}),
    };

    expect(JSON.parse(JSON.stringify(rebuilt))).toEqual(raw);
  });

  it.each(outcomeMessages)("%s uses only declared vocabulary", (name) => {
    const raw = wire(name);
    expect(raw.kind).toBe(COMMAND_OUTCOME_KIND);
    expect(fixture.vocabularies.outcomes).toContain(raw.outcome);
    expect(fixture.vocabularies.resourceTypes).toContain(raw.resourceType);
    if (raw.reason !== undefined) {
      expect(fixture.vocabularies.failureReasons).toContain(raw.reason);
    }
  });

  /**
   * ADR 0019: `reason` is present when and only when the outcome is
   * `failed`. A `timed_out` carrying a reason, or a `failed` without
   * one, breaks the aggregation the whole mechanism exists for — a
   * failure that cannot be grouped is a failure nobody acts on.
   */
  it("carries a reason exactly when the outcome is failed", () => {
    for (const name of outcomeMessages) {
      const raw = wire(name);
      expect(
        raw.reason !== undefined,
        `${name}: reason presence must track outcome === "failed"`,
      ).toBe(raw.outcome === "failed");
    }
  });

  /**
   * `epoch` and `seq` are optional together, and an outcome for an
   * unsequenced command must stay reportable — otherwise acting on such
   * a command becomes an unmeasurable switch, the exact gap ADR 0019
   * closes. Builds that ran against a relay stamping nothing are real
   * (the relay half of #210 shipped first), not hypothetical.
   */
  it("keeps an unsequenced outcome reportable", () => {
    const raw = wire("commandOutcomeUnsequenced");
    expect(raw.epoch).toBeUndefined();
    expect(raw.seq).toBeUndefined();
    expect(raw.outcome).toBe("succeeded");
  });

  it("pins the timed-out bound to the shared constant", () => {
    const raw = wire("commandOutcomeTimedOut");
    expect(raw.outcome).toBe("timed_out");
    expect(raw.durationMs).toBe(COMMAND_OUTCOME_TIMEOUT_MS);
    expect(raw.reason).toBeUndefined();
  });
});
