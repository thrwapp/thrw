import { describe, expect, it } from "vitest";
import {
  commandsTopic,
  eventsTopic,
  heartbeatTopic,
  PRIORITY_ORDER,
  protocolPackageName,
  stateTopic,
  TopicQos,
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
});
