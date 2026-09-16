import { describe, expect, it } from "vitest";
import {
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
      expect(eventsTopic("acme", "node-1")).toBe(
        "thrw/acme/nodes/node-1/events",
      );
    });

    it("builds the commands topic", () => {
      expect(commandsTopic("acme", "node-1")).toBe(
        "thrw/acme/commands/node-1",
      );
    });

    it("builds the state topic", () => {
      expect(stateTopic("acme")).toBe("thrw/acme/state");
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
