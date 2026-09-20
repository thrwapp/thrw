import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  commandsTopic,
  eventsTopic,
  heartbeatTopic,
  stateTopic,
  type ResourceType,
} from "../src/index.js";

/**
 * The shared contract all three topic builders must satisfy (#171).
 *
 * TypeScript here, Swift in `adapter-mac`'s `TopicsTests`, Kotlin in
 * `adapter-android`'s `TopicsTest` - all three read this same file. Until
 * now each had its own tests and nothing asserted they agreed, so they
 * could drift apart silently and the only symptom would be a node going
 * quiet on real hardware.
 */
const fixture = JSON.parse(
  readFileSync(new URL("../fixtures/topics.json", import.meta.url), "utf8"),
) as {
  account: string;
  node: string;
  resourceType: ResourceType;
  topics: Record<string, string>;
  hid: Record<string, string>;
};

describe("topic builders match the cross-platform fixture", () => {
  const { account, node, resourceType, topics } = fixture;

  it("builds the events topic", () => {
    expect(eventsTopic(account, node, resourceType)).toBe(topics.events);
  });

  it("builds the commands topic", () => {
    expect(commandsTopic(account, node, resourceType)).toBe(topics.commands);
  });

  it("builds the state topic", () => {
    expect(stateTopic(account, resourceType)).toBe(topics.state);
  });

  /** No resource segment - see the builder's own doc and ADR 0015. */
  it("builds the heartbeat topic without a resource segment", () => {
    expect(heartbeatTopic(account, node)).toBe(topics.heartbeat);
    expect(heartbeatTopic(account, node)).not.toContain(resourceType);
  });

  it("builds hid topics with the same shape", () => {
    expect(eventsTopic(account, node, "hid")).toBe(fixture.hid.events);
    expect(commandsTopic(account, node, "hid")).toBe(fixture.hid.commands);
    expect(stateTopic(account, "hid")).toBe(fixture.hid.state);
  });
});
