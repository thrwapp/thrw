import type { NodeManifest } from "@thrw/protocol";

// Device registry per docs/spec/architecture.md's "System components"
// section: the relay "never assumes a platform's capabilities —
// everything it knows about a node comes from that node's capability
// manifest at registration time." Accordingly, this stores whatever
// NodeManifest it's given and never branches on `platform` or any other
// field — adding a new platform means writing a new adapter, not
// changing this registry.
//
// Pure in-memory keyed storage - no MQTT, no I/O, no connection state
// machine (that's a frozen contract per ADR 0010/0011/0013 and out of
// scope here).
export class DeviceRegistry {
  private readonly nodes = new Map<string, NodeManifest>();

  register(manifest: NodeManifest): void {
    this.nodes.set(manifest.nodeId, manifest);
  }

  unregister(nodeId: string): void {
    this.nodes.delete(nodeId);
  }

  getById(nodeId: string): NodeManifest | undefined {
    return this.nodes.get(nodeId);
  }

  listAll(): NodeManifest[] {
    return Array.from(this.nodes.values());
  }
}
