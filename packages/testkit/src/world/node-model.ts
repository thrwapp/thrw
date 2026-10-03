import type { EventKind } from "@thrw/protocol";

import type { WorldParameters } from "./parameters.js";

/**
 * What a node model is told about the physical world (#329).
 *
 * Deliberately *physical*. A scenario file says "the user pressed play";
 * it never says "the Mac emitted `media`". Translating the first into the
 * second is this model's whole job, and getting that translation wrong is
 * the class of bug the simulator exists to catch — every September defect
 * (#288, #295, #298, #303) lived in exactly that gap.
 */
export type PhysicalSignal =
  /** The user started audio on this device. */
  | { readonly kind: "audio_started" }
  /** The user stopped or paused it. */
  | { readonly kind: "audio_stopped" }
  /** A brief interruption that is not a stop: buffering, a track change. */
  | { readonly kind: "audio_blip"; readonly forMs: number }
  /** A cellular or VoIP call began on this device. */
  | { readonly kind: "call_started" }
  | { readonly kind: "call_ended" }
  /** A VoIP app opened with no call in progress (N3). */
  | { readonly kind: "voip_app_opened" }
  | { readonly kind: "voip_call_started" }
  | { readonly kind: "voip_call_ended" }
  /** The user tapped Claim / Release on this device. */
  | { readonly kind: "manual_claim" }
  | { readonly kind: "manual_release" }
  /**
   * thrw itself moved the audio route onto or off this device. Not a user
   * action — this is the perturbation that causes #298 and #295.
   */
  | { readonly kind: "route_arrived" }
  | { readonly kind: "route_left" };

/** What the node decides to tell the relay. */
export interface NodeEmission {
  readonly atMs: number;
  readonly kind: "event" | "event_end";
  readonly type: EventKind;
}

export interface NodeModelOptions {
  readonly platform: "mac" | "android";
  readonly parameters: WorldParameters;
}

/**
 * One adapter's trigger, debounce, cooldown and route-reporting
 * decisions, in TypeScript.
 *
 * ## Why Mac and Pixel are one class with branches rather than two
 *
 * They differ in four specific, documented ways, listed below. Every
 * other decision — the self-cooldown, the route-settle window, event
 * bookkeeping — is genuinely shared, and ADR 0019/0010 require it to stay
 * shared. Two classes would let the shared half drift, which is exactly
 * what ADR 0022's macOS/Android divergence cost.
 *
 * The four differences:
 *
 * 1. **The Mac cannot detect phone calls at all**
 *    (`architecture.md`, "Mac's trigger-detection gap"). A `call_started`
 *    on the Mac emits nothing. This is why M1 is phone-claims-from-Mac
 *    and has no mirror.
 * 2. **The Mac's media signal is perturbed by thrw's own handover.** It
 *    watches `kAudioDevicePropertyDeviceIsRunningSomewhere` on the
 *    *default output device*, which changes when the route moves, so the
 *    signal drops for ~500ms through no fault of the user (#298). The
 *    Pixel reads `MediaSessionManager`, which is per-session and does
 *    not care which device is active.
 * 3. **The Mac debounces media stops by 4s** to survive (2). The Pixel
 *    has no equivalent because it does not need one; it distinguishes
 *    `TRANSIENT` (buffering, connecting) from `STOPPED` instead (#288).
 * 4. **The audio gate differs.** Android pauses and resumes the user's
 *    media, which the media monitor can then misread as a stop (#295).
 *    macOS attempts to mute and silently fails on AirPods (#304), so its
 *    media keeps playing but its signal is *not* perturbed by a pause.
 */
export class NodeModel {
  private readonly platform: "mac" | "android";
  private readonly p: WorldParameters;

  /** Triggers this node has told the relay are active. */
  private readonly active = new Set<EventKind>();

  /** Physically playing audio, as the user would describe it. */
  private audioPlaying = false;

  /** ADR 0010's self-cooldown, armed by this node's own claim/release. */
  private cooldownUntilMs = 0;

  /** `RouteTransition`: route readings are withheld until this passes. */
  private settlingUntilMs = 0;

  /** Does this node physically hold the audio route? */
  private holdsRoute = false;

  /** A pending Mac media-stop, waiting out the 4s debounce. */
  private pendingStopAtMs: number | null = null;

  /** A window where the Mac's audio signal is false for thrw's own reason. */
  private deviceChangeGapUntilMs = 0;

  /** What the monitor last read, so only *edges* are acted on. */
  private lastSignalReading = false;

  constructor(options: NodeModelOptions) {
    this.platform = options.platform;
    this.p = options.parameters;
  }

  /**
   * Establishes state as it was *before* the scenario starts, with no
   * side effects.
   *
   * `initial` in a scenario file describes the world, not a sequence of
   * things thrw just did. Feeding it through `apply` instead armed the
   * self-cooldown, which then suppressed the scenario's own initial media
   * start - so `initial: { holder: pixel, playing: [pixel] }` produced a
   * Pixel with no media. Caught by R298 failing for the wrong reason.
   */
  seedInitialState(options: { readonly holdsRoute: boolean; readonly playing: boolean }): void {
    this.holdsRoute = options.holdsRoute;
    this.audioPlaying = options.playing;
    if (options.playing) this.active.add("media");
    // Deliberately no cooldown and no settle window: nothing has
    // happened yet, so the node has nothing to be recovering from.
    this.cooldownUntilMs = 0;
    this.settlingUntilMs = 0;
    this.deviceChangeGapUntilMs = 0;
    this.pendingStopAtMs = null;
    this.lastSignalReading = options.playing;
  }

  activeTriggers(): readonly EventKind[] {
    return [...this.active];
  }

  /**
   * What this node would put in `observedRoutes` right now.
   *
   * `undefined` means the key is **absent** — ADR 0018's "no
   * information", which the relay must not read as `false`. That
   * distinction is the whole of #303 and #307.
   */
  observedRoute(nowMs: number): boolean | undefined {
    if (nowMs < this.settlingUntilMs) return undefined;
    return this.holdsRoute;
  }

  /** Whether a trigger is exempt from the self-cooldown (ADR 0010). */
  private bypassesCooldown(type: EventKind): boolean {
    return type === "call" || type === "manual_claim";
  }

  private emit(
    out: NodeEmission[],
    atMs: number,
    kind: "event" | "event_end",
    type: EventKind,
  ): void {
    if (kind === "event") {
      // `emitEvent` records into the active set only when it actually
      // publishes, so a start suppressed by the cooldown is simply lost -
      // and its eventual end is then an `event_end` with no start, which
      // is the anomaly the compatibility matrix records twice.
      if (atMs < this.cooldownUntilMs && !this.bypassesCooldown(type)) return;
      if (this.active.has(type)) return;
      this.active.add(type);
    } else {
      if (!this.active.has(type)) return;
      this.active.delete(type);
    }
    out.push({ atMs, kind, type });
  }

  /**
   * Feeds one physical signal in, returning what the node tells the relay.
   *
   * Returns emissions rather than publishing, so the runner controls
   * ordering on the virtual clock and nothing here needs a transport.
   */
  apply(signal: PhysicalSignal, nowMs: number): NodeEmission[] {
    const out: NodeEmission[] = [];

    switch (signal.kind) {
      case "audio_started":
        this.audioPlaying = true;
        this.pendingStopAtMs = null;
        if (this.platform === "mac") {
          this.evaluateSignal(out, nowMs);
        } else {
          this.emit(out, nowMs, "event", "media");
        }
        break;

      case "audio_stopped":
        this.audioPlaying = false;
        if (this.platform === "mac") {
          // Difference 3: debounced, because difference 2 makes a bare
          // stop untrustworthy. Resolved by `tick`.
          this.evaluateSignal(out, nowMs);
        } else {
          this.emit(out, nowMs, "event_end", "media");
        }
        break;

      case "audio_blip":
        // The Pixel classifies this as TRANSIENT and reports nothing
        // (#288). The Mac sees its device stop briefly, which its
        // debounce is there to absorb - so also nothing, provided the
        // blip is shorter than the debounce.
        if (signal.forMs >= this.p.macMediaStopDebounceMs && this.platform === "mac") {
          this.pendingStopAtMs = nowMs + this.p.macMediaStopDebounceMs;
        }
        break;

      case "call_started":
        // Difference 1: the Mac cannot see phone calls.
        if (this.platform === "android") this.emit(out, nowMs, "event", "call");
        break;

      case "call_ended":
        if (this.platform === "android") this.emit(out, nowMs, "event_end", "call");
        break;

      case "voip_app_opened":
        // N3: an open app with no call is not a trigger on either
        // platform. Modelled explicitly so N3 can assert it.
        break;

      case "voip_call_started":
        this.emit(out, nowMs, "event", "voip");
        break;

      case "voip_call_ended":
        this.emit(out, nowMs, "event_end", "voip");
        break;

      case "manual_claim":
        this.emit(out, nowMs, "event", "manual_claim");
        break;

      case "manual_release":
        this.emit(out, nowMs, "event_end", "manual_claim");
        break;

      case "route_arrived":
      case "route_left":
        this.holdsRoute = signal.kind === "route_arrived";
        this.settlingUntilMs = nowMs + this.p.routeSettleMs;
        this.cooldownUntilMs = nowMs + this.p.selfCooldownMs;
        this.onRouteMoved(out, nowMs);
        break;
    }

    return out;
  }

  /**
   * Difference 2, and the mechanism behind #298.
   *
   * The Mac's media trigger watches
   * `kAudioDevicePropertyDeviceIsRunningSomewhere` on the **default
   * output device**, and thrw changes which device that is on every
   * handover. So the signal genuinely reads false for ~500ms, through no
   * action of the user's, and the monitor's `audioStopped()` fires.
   *
   * It is the 4s debounce that absorbs it: the signal returns long before
   * the debounce expires, `audioStarted()` cancels the pending stop, and
   * nothing is published. Remove the debounce and the stop lands, the
   * relay recomputes without this node's media, and the holder bounces -
   * which is exactly what #298 was filed for.
   *
   * Modelled as a *real* transient stop rather than a flag, because a
   * flag is what this model had first and it made R298 pass with the
   * debounce removed - the scenario looked green while reproducing
   * nothing.
   *
   * The Pixel has no equivalent: `MediaSessionManager` is per-session and
   * does not care which device is active.
   */
  private onRouteMoved(out: NodeEmission[], nowMs: number): void {
    if (this.platform !== "mac") return;
    this.deviceChangeGapUntilMs = nowMs + this.p.macDeviceChangeAudioGapMs;
    this.evaluateSignal(out, nowMs);
  }

  /**
   * What the Mac's monitor currently reads, as opposed to what the user
   * is doing.
   *
   * `audioPlaying` is the user's truth. This is
   * `kAudioDevicePropertyDeviceIsRunningSomewhere`, which also reads
   * false for ~500ms whenever thrw changes the default output device.
   */
  private signalReadsPlaying(nowMs: number): boolean {
    if (this.platform !== "mac") return this.audioPlaying;
    return this.audioPlaying && nowMs >= this.deviceChangeGapUntilMs;
  }

  /**
   * Runs the Mac's media monitor against the current signal (#298).
   *
   * Signal-driven rather than case-by-case, because the first version of
   * this model set a flag on a route move and never acted on it - so
   * R298 passed with the debounce removed, reproducing nothing while
   * looking green. The model-resolution probe is what caught that.
   *
   * The oscillation #298 was filed for needs **both** edges: the signal
   * dropping publishes an `event_end`, and the signal returning publishes
   * a fresh `media`. One without the other is a single spurious stop, not
   * the bounce-every-ten-seconds the user saw.
   *
   * The debounce is what makes the drop harmless: the signal returns long
   * before 4s elapses, so the pending stop is cancelled and neither edge
   * is ever published.
   */
  private evaluateSignal(out: NodeEmission[], nowMs: number): void {
    if (this.platform !== "mac") return;
    const reads = this.signalReadsPlaying(nowMs);
    if (reads === this.lastSignalReading) return;
    this.lastSignalReading = reads;

    if (reads) {
      // Signal came back. Cancels a pending stop if the debounce is
      // still running; otherwise this is the second edge of the bounce.
      if (this.pendingStopAtMs !== null) {
        this.pendingStopAtMs = null;
        return;
      }
      this.emit(out, nowMs, "event", "media");
      return;
    }

    if (this.p.macMediaStopDebounceMs > 0) {
      this.pendingStopAtMs = nowMs + this.p.macMediaStopDebounceMs;
    } else {
      this.emit(out, nowMs, "event_end", "media");
    }
  }

  /**
   * Advances internal timers to `nowMs`, returning anything that fell due.
   *
   * Only the Mac's stop debounce today. Called by the runner on every
   * clock advance, so a scenario never has to know it exists.
   */
  tick(nowMs: number): NodeEmission[] {
    const out: NodeEmission[] = [];
    // The signal may have come back since the last tick, which is what
    // cancels a debounced stop.
    this.evaluateSignal(out, nowMs);

    // The Mac's monitor **polls** `DeviceIsRunningSomewhere`; it does not
    // only react to edges. So if audio is playing and this node has no
    // `media` recorded, it keeps trying to publish one - and a try
    // suppressed by the self-cooldown succeeds once the cooldown expires.
    //
    // That retry is what closes #298's loop, and without it the model
    // showed no bounce even with the debounce removed: the spurious end
    // published, the restart was swallowed by the cooldown, and nothing
    // ever re-offered it. The observed ~10s bounce period is this 6s
    // cooldown plus the settle, which is the evidence the mechanism is
    // right.
    if (this.platform === "mac" && this.signalReadsPlaying(nowMs) && !this.active.has("media")) {
      this.emit(out, nowMs, "event", "media");
    }
    if (this.pendingStopAtMs !== null && nowMs >= this.pendingStopAtMs) {
      this.pendingStopAtMs = null;
      // The debounce expired with the signal still down. Either the user
      // really did stop, or - pre-#298 - thrw's own handover did.
      if (!this.signalReadsPlaying(nowMs)) this.emit(out, nowMs, "event_end", "media");
    }
    return out;
  }

  /**
   * Whether the Mac's audio signal is currently reading false for thrw's
   * own reason rather than the user's.
   *
   * Exposed for assertions: a scenario proving #298 needs to distinguish
   * "the user stopped" from "thrw moved the device".
   */
  inDeviceChangeGap(nowMs: number): boolean {
    return nowMs < this.deviceChangeGapUntilMs;
  }
}
