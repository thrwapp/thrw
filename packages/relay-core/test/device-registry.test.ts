import type { NodeManifest } from "@thrw/protocol";
import { describe, expect, it } from "vitest";
import { DeviceRegistry } from "../src/device-registry";

function manifest(overrides: Partial<NodeManifest> = {}): NodeManifest {
  return {
    nodeId: "node-a",
    platform: "android",
    displayName: "Pixel 8",
    adapterVersion: "1.0.0",
    supportedEventKinds: ["call", "media"],
    ...overrides,
  };
}

describe("DeviceRegistry", () => {
  it("has no nodes when first created", () => {
    const registry = new DeviceRegistry();
    expect(registry.listAll()).toEqual([]);
  });

  it("stores a node's manifest at registration time and returns it by id", () => {
    const registry = new DeviceRegistry();
    const nodeA = manifest();

    registry.register(nodeA);

    expect(registry.getById("node-a")).toEqual(nodeA);
  });

  it("returns undefined from getById for a node that was never registered", () => {
    const registry = new DeviceRegistry();
    expect(registry.getById("does-not-exist")).toBeUndefined();
  });

  it("lists every registered node regardless of platform, without special-casing any of them", () => {
    const registry = new DeviceRegistry();
    const nodeA = manifest({ nodeId: "node-a", platform: "android" });
    const nodeB = manifest({ nodeId: "node-b", platform: "mac" });
    const nodeC = manifest({ nodeId: "node-c", platform: "ipad" });
    const nodeD = manifest({ nodeId: "node-d", platform: "linux" });

    registry.register(nodeA);
    registry.register(nodeB);
    registry.register(nodeC);
    registry.register(nodeD);

    expect(registry.listAll()).toEqual(
      expect.arrayContaining([nodeA, nodeB, nodeC, nodeD]),
    );
    expect(registry.listAll()).toHaveLength(4);
  });

  it("re-registering the same nodeId overwrites the stored manifest", () => {
    const registry = new DeviceRegistry();
    registry.register(manifest({ adapterVersion: "1.0.0" }));
    registry.register(manifest({ adapterVersion: "2.0.0" }));

    expect(registry.getById("node-a")?.adapterVersion).toBe("2.0.0");
    expect(registry.listAll()).toHaveLength(1);
  });

  it("removes a node on unregister so it no longer appears by id or in the full list", () => {
    const registry = new DeviceRegistry();
    registry.register(manifest());

    registry.unregister("node-a");

    expect(registry.getById("node-a")).toBeUndefined();
    expect(registry.listAll()).toEqual([]);
  });

  it("unregistering an unknown nodeId is a no-op rather than throwing", () => {
    const registry = new DeviceRegistry();
    expect(() => registry.unregister("never-registered")).not.toThrow();
  });

  it("finds a still-registered node by id after other nodes have been unregistered", () => {
    const registry = new DeviceRegistry();
    const nodeA = manifest({ nodeId: "node-a" });
    const nodeB = manifest({ nodeId: "node-b" });
    const nodeC = manifest({ nodeId: "node-c" });

    registry.register(nodeA);
    registry.register(nodeB);
    registry.register(nodeC);

    registry.unregister("node-a");
    registry.unregister("node-c");

    expect(registry.getById("node-b")).toEqual(nodeB);
    expect(registry.listAll()).toEqual([nodeB]);
  });
});
