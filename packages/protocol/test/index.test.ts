import { describe, expect, it } from "vitest";
import {
  COMMAND_OUTCOME_KIND,
  COMMAND_OUTCOME_TIMEOUT_MS,
  commandsTopic,
  ConnectionStateMachine,
  eventsTopic,
  heartbeatTopic,
  IllegalConnectionTransitionError,
  PRIORITY_ORDER,
  protocolPackageName,
  stateTopic,
  TopicQos,
  type ConnectionState,
  type EventKind,
} from "../src/index";

describe("@thrw/protocol", () => {
  it("exposes its package name as a placeholder export", () => {
    expect(protocolPackageName).toBe("@thrw/protocol");
  });

  describe("topic builders", () => {
    it("builds the events topic", () => {
      expect(eventsTopic("acme", "node-1", "audio")).toBe(
        "thrw/acme/nodes/node-1/audio/events",
      );
    });

    it("builds the commands topic", () => {
      expect(commandsTopic("acme", "node-1", "audio")).toBe(
        "thrw/acme/commands/node-1/audio",
      );
    });

    it("builds the state topic", () => {
      expect(stateTopic("acme", "audio")).toBe("thrw/acme/state/audio");
    });

    it("builds the heartbeat topic", () => {
      expect(heartbeatTopic("acme", "node-1")).toBe(
        "thrw/acme/nodes/node-1/heartbeat",
      );
    });
  });

  describe("TopicQos", () => {
    it("records events as QoS 1", () => {
      expect(TopicQos.events).toEqual({ qos: 1 });
    });

    it("records commands as QoS 1", () => {
      expect(TopicQos.commands).toEqual({ qos: 1 });
    });

    it("records state as retained", () => {
      expect(TopicQos.state).toEqual({ retained: true });
    });

    it("records heartbeat as QoS 0", () => {
      expect(TopicQos.heartbeat).toEqual({ qos: 0 });
    });
  });

  describe("PRIORITY_ORDER", () => {
    it("has exactly the 4 EventKind values in documented rank order", () => {
      const expected: EventKind[] = ["call", "manual_claim", "voip", "media"];
      expect(PRIORITY_ORDER).toEqual(expected);
      expect(PRIORITY_ORDER).toHaveLength(4);
    });
  });

  describe("command outcomes (ADR 0019)", () => {
    it("pins the 8s bound every adapter must enforce identically", () => {
      // ADR 0019 fixes this at 8s and #206 criterion 2 requires it be the
      // same everywhere: an adapter choosing its own bound makes the
      // aggregate success rate meaningless, because an outcome would not
      // mean the same thing in every row.
      //
      // It guarantees *termination*, not latency - ADR 0007 owns latency,
      // with its own 3.5-4s p95 SLO. If this ever looks wrong because
      // switches are slow, the bug is elsewhere; changing this only
      // changes when a stuck command gives up.
      //
      // adapter-mac and adapter-android each assert against this same
      // number in their own suites - three hand-written implementations,
      // nothing else catches them drifting.
      expect(COMMAND_OUTCOME_TIMEOUT_MS).toBe(8_000);
    });

    it("uses a kind discriminator on the events topic rather than a new topic", () => {
      // The events topic is the only node-publishes topic in the frozen
      // set (ADR 0001/0015), and already carries several kinds. An
      // outcome follows that precedent - so ADR 0019 needs no topic
      // change, which is what let it land without a second flag day.
      expect(COMMAND_OUTCOME_KIND).toBe("command_outcome");
    });
  });

  describe("ConnectionStateMachine", () => {
    const ALL_STATES: ConnectionState[] = [
      "idle",
      "pre-claim",
      "claim",
      "active",
    ];

    const LEGAL_TRANSITIONS: [ConnectionState, ConnectionState][] = [
      ["idle", "pre-claim"],
      ["pre-claim", "claim"],
      ["pre-claim", "idle"],
      ["claim", "active"],
      ["active", "idle"],
    ];

    it("starts in idle by default", () => {
      expect(new ConnectionStateMachine().state).toBe("idle");
    });

    it("accepts an explicit initial state", () => {
      expect(new ConnectionStateMachine("active").state).toBe("active");
    });

    for (const [from, to] of LEGAL_TRANSITIONS) {
      it(`allows ${from} -> ${to}`, () => {
        const machine = new ConnectionStateMachine(from);
        expect(machine.canTransition(to)).toBe(true);
        expect(machine.transition(to)).toBe(to);
        expect(machine.state).toBe(to);
      });
    }

    const legalPairs = new Set(LEGAL_TRANSITIONS.map(([f, t]) => `${f}->${t}`));
    const illegalPairs: [ConnectionState, ConnectionState][] = [];
    for (const from of ALL_STATES) {
      for (const to of ALL_STATES) {
        if (!legalPairs.has(`${from}->${to}`)) {
          illegalPairs.push([from, to]);
        }
      }
    }

    it("has exactly 11 illegal transition pairs (16 total - 5 legal)", () => {
      expect(illegalPairs).toHaveLength(11);
    });

    for (const [from, to] of illegalPairs) {
      it(`rejects ${from} -> ${to}`, () => {
        const machine = new ConnectionStateMachine(from);
        expect(machine.canTransition(to)).toBe(false);
        expect(() => machine.transition(to)).toThrow(
          IllegalConnectionTransitionError,
        );
        expect(machine.state).toBe(from);
      });
    }

    it("does not add a cooldown state", () => {
      expect(ALL_STATES).not.toContain("cooldown");
      expect(ALL_STATES).toHaveLength(4);
    });
  });
});
