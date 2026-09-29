import { readFileSync } from "node:fs";
import { PRIORITY_ORDER, type EventKind } from "@thrw/protocol";
import { describe, expect, it } from "vitest";
import type {
  CommandPayload,
  EventPayload,
  SequencedCommandPayload,
  StatePayload,
} from "../src/mqtt-client.js";

/**
 * The relay's half of the shared payload contract, asserted against
 * `packages/protocol/fixtures/wire.json` (#317).
 *
 * The wire format is declared in two TypeScript places: `packages/
 * protocol` owns the constants, the vocabularies and
 * `CommandOutcomePayload` (asserted in its own `wire-fixture.test.ts`),
 * and this package owns the four shapes below. One fixture, asserted by
 * whichever module declares each piece — the alternative is a second
 * copy of the fixture, which is the problem it exists to solve.
 *
 * Swift (`adapter-mac`) and Kotlin (`adapter-android`) mirror *all* of
 * it in one file each, because an adapter declares both halves.
 *
 * Runtime assertions only, for the reason the protocol-side test spells
 * out: both tsconfigs are `"include": ["src"]`, so `tsc` never sees a
 * test file and a `satisfies` clause here would be checked by nothing.
 */

interface WireFixture {
  vocabularies: {
    eventKinds: EventKind[];
    commandTypes: string[];
    resourceTypes: string[];
    platforms: string[];
  };
  kinds: { register: string; eventEnd: string; commandOutcome: string };
  messages: Record<string, Record<string, unknown>>;
}

const fixture = JSON.parse(
  readFileSync(
    new URL("../../protocol/fixtures/wire.json", import.meta.url),
    "utf8",
  ),
) as WireFixture;

/** `$comment` keys are documentation for the reader, never wire fields. */
function wire(name: string): Record<string, unknown> {
  const message = fixture.messages[name];
  expect(message, `fixture has no message named ${name}`).toBeDefined();
  const { $comment: _dropped, ...rest } = message;
  return rest;
}

describe("EventPayload matches the cross-platform fixture", () => {
  it("represents an event without loss", () => {
    const raw = wire("event");
    const rebuilt: EventPayload = {
      type: raw.type as EventKind,
      priority: raw.priority as number,
    };
    expect(JSON.parse(JSON.stringify(rebuilt))).toEqual(raw);
  });

  /**
   * An ordinary event carries **no** `kind`, and that absence is what
   * makes the discriminator on the other three message shapes
   * backward-compatible: adding a kind cannot change how an existing
   * event parses (docs/handoffs/67.md). A mirror that started stamping
   * `kind` on events would be accepted by the relay and would quietly
   * reclassify every trigger.
   */
  it("carries no kind discriminator", () => {
    expect(wire("event").kind).toBeUndefined();
  });

  /**
   * The fixture's `priority` has to be consistent with the priority
   * order it also declares, or the two halves of the same file disagree.
   */
  it("uses a priority consistent with the declared order", () => {
    const raw = wire("event");
    expect(PRIORITY_ORDER.indexOf(raw.type as EventKind)).toBe(raw.priority);
  });
});

describe("EventEndPayload matches the cross-platform fixture", () => {
  /**
   * Ending a trigger needs only its kind, so there is deliberately no
   * `priority` — `PriorityEngine.endEvent(nodeId, type)` takes nothing
   * else. A mirror that added one would be inventing a field the relay
   * ignores.
   */
  it("carries a kind and a type, and no priority", () => {
    const raw = wire("eventEnd");
    expect(raw.kind).toBe(fixture.kinds.eventEnd);
    expect(fixture.vocabularies.eventKinds).toContain(raw.type);
    expect(raw.priority).toBeUndefined();
  });
});

describe("RegistrationPayload matches the cross-platform fixture", () => {
  const registrations = ["registration", "registrationNoRouteKnown"];

  it.each(registrations)("%s declares only known vocabulary", (name) => {
    const raw = wire(name);
    expect(raw.kind).toBe(fixture.kinds.register);

    const manifest = raw.manifest as Record<string, unknown>;
    expect(fixture.vocabularies.platforms).toContain(manifest.platform);
    for (const kind of manifest.supportedEventKinds as string[]) {
      expect(fixture.vocabularies.eventKinds).toContain(kind);
    }
    for (const resource of manifest.supportedResourceTypes as string[]) {
      expect(fixture.vocabularies.resourceTypes).toContain(resource);
    }
    for (const active of raw.activeEvents as string[]) {
      expect(fixture.vocabularies.eventKinds).toContain(active);
    }
    for (const resource of Object.keys(raw.observedRoutes as object)) {
      expect(fixture.vocabularies.resourceTypes).toContain(resource);
    }
  });

  /**
   * `observedRoutes` absence is meaningful and is the assertion most
   * easily "simplified" away (#191). A missing key means *cannot
   * determine* and leaves the relay's record alone; `false` positively
   * asserts this node does not hold the resource and is grounds for
   * corrective action. Collapsing the two hands the relay a fabricated
   * disagreement — and a node reporting `{}` repeatedly is #303's
   * signature, which the relay must be able to tell from a denial.
   */
  it("keeps an absent route distinct from a false one", () => {
    expect(wire("registration").observedRoutes).toEqual({ audio: true });
    expect(wire("registrationNoRouteKnown").observedRoutes).toEqual({});
  });

  /**
   * The first registration sends an *empty* `activeEvents`, not an
   * omitted one — it is sent on every registration including the first
   * (#178), because a relay that restarted recovers its picture from
   * this field rather than from edges it may have missed.
   */
  it("sends activeEvents even when empty", () => {
    expect(wire("registrationNoRouteKnown").activeEvents).toEqual([]);
  });

  /**
   * The Mac cannot detect phone calls at all (architecture.md, "Mac's
   * trigger-detection gap"), so the two manifests in the fixture differ
   * in exactly that way. Pinning it keeps the fixture honest about the
   * reference pair rather than describing two identical nodes.
   */
  it("reflects the Mac's trigger-detection gap", () => {
    const mac = (wire("registration").manifest as Record<string, unknown>);
    const pixel = (wire("registrationNoRouteKnown").manifest as Record<string, unknown>);
    expect(mac.supportedEventKinds).not.toContain("call");
    expect(pixel.supportedEventKinds).toContain("call");
  });
});

describe("CommandPayload matches the cross-platform fixture", () => {
  it("represents a sequenced command without loss", () => {
    const raw = wire("command");
    const rebuilt: SequencedCommandPayload = {
      type: raw.type as CommandPayload["type"],
      seq: raw.seq as number,
      epoch: raw.epoch as string,
    };
    expect(JSON.parse(JSON.stringify(rebuilt))).toEqual(raw);
  });

  /**
   * A command carrying neither `epoch` nor `seq` must still decode and
   * be acted on. Not defensive padding: the relay half of #210 shipped
   * before the adapter half, so builds exist that ran against a relay
   * stamping nothing, and both `CommandSequenceGate`s treat an
   * unsequenced command as acceptable rather than stale. Making these
   * required would brick those builds.
   */
  it("represents an unsequenced command without loss", () => {
    const raw = wire("commandUnsequenced");
    const rebuilt: CommandPayload = { type: raw.type as CommandPayload["type"] };
    expect(JSON.parse(JSON.stringify(rebuilt))).toEqual(raw);
    expect(raw.seq).toBeUndefined();
    expect(raw.epoch).toBeUndefined();
  });

  it.each(["command", "commandUnsequenced"])("%s uses a declared command type", (name) => {
    expect(fixture.vocabularies.commandTypes).toContain(wire(name).type);
  });
});

describe("StatePayload matches the cross-platform fixture", () => {
  it("represents a held resource without loss", () => {
    const raw = wire("state");
    const rebuilt: StatePayload = { holder: raw.holder as string };
    expect(JSON.parse(JSON.stringify(rebuilt))).toEqual(raw);
  });

  /**
   * `{"holder": null}` is a real answer the relay genuinely publishes,
   * and it must stay on the wire as an explicit `null` rather than an
   * omitted key. Both adapters keep "nobody holds it" distinct from "we
   * have not heard from the relay", because storing both as a nil string
   * makes the UI assert confidently that nobody holds the headset when
   * the truth is that it has no idea — #308's family of bug.
   */
  it("keeps an explicit null holder distinct from an absent one", () => {
    const raw = wire("stateNoHolder");
    const rebuilt: StatePayload = { holder: null };
    expect(JSON.parse(JSON.stringify(rebuilt))).toEqual(raw);
    expect("holder" in raw).toBe(true);
    expect(raw.holder).toBeNull();
  });
});
