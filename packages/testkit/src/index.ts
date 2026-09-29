export const testkitPackageName = "@thrw/testkit";

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export { VirtualClock } from "./virtual-clock.js";
export {
  InMemoryBus,
  type DispatchedCommand,
  type InMemoryBusOptions,
  type PublishedState,
} from "./in-memory-bus.js";
