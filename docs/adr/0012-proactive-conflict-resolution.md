# ADR 0012: Proactively detect and help resolve competing connection managers

## Status
Accepted

## Context
ADR 0010 establishes that thrw must detect when another app or system
feature is also trying to manage the same Bluetooth connection, and
avoid fighting it. Detection alone leaves the user to manually
diagnose and fix the conflict themselves, which is exactly the kind of
Bluetooth-settings friction thrw exists to remove. Because thrw can see
which competing apps or OS features are active on a given device, it
is uniquely positioned to also detect *misconfiguration* relative to
its own expected state, and to guide the user toward the settings that
make thrw's switching actually work as intended — turning what could
be a silent source of failed switches into a specific, actionable
recommendation.

## Decision
Each adapter, in addition to the conflict detection in ADR 0010, runs
periodic checks (on startup and after any failed/unexpected switch)
against a set of known "prioritize thrw" configuration states:

- macOS: is the headset set to auto-connect in system Bluetooth
  settings in a way that could race with thrw's managed disconnects?
  Is a competing app (ToothFairy, AirBuddy) set to launch at login?
- Android: is the headset excluded from Android's own "automatically
  switch active device" feature (where present) so it doesn't compete
  with thrw's own switching logic? Are battery optimization settings
  likely to kill thrw's background service or notification listener,
  silently breaking call detection?
- Both: is the app-priority allowlist (ADR 0010, item 5) missing an
  app the adapter has observed actively contending for the same
  device's audio routing?

When a misconfiguration is detected, the adapter surfaces a specific,
actionable recommendation to the user — not a generic warning. For
example: "Android's automatic switching is also managing your AirPods,
which can conflict with thrw. Turn off automatic switching for this
device to let thrw manage it fully" with a direct link or button to
the relevant system settings screen where the platform allows it.

This check result is also reported to telemetry (anonymized,
aggregated) specifically because it is the leading indicator of "thrw
isn't working as expected" for a given user — a failed or slow switch
correlated with a known misconfiguration is far more actionable than a
generic latency data point, and should feed directly into the
troubleshooting wiki's auto-generated entries (per the existing
telemetry -> wiki content pipeline) as well as an in-app one-time
prompt.

## Rationale
Because thrw already needs the detection capability from ADR 0010 to
avoid fighting other connection managers, extending that same signal
into a proactive, specific recommendation is a small incremental cost
for a disproportionate improvement in real-world reliability. Most
users will never manually discover that, for example, Android's own
switching feature is fighting thrw's — they will just experience thrw
as unreliable and churn. Converting the conflict-detection signal thrw
already has to build into an explicit "here's the one setting to
change" moment converts a silent failure mode into a solved
onboarding step, and does it using data only thrw is positioned to
have (which apps and OS features are actively contending for this
specific headset, on this specific device, right now).

## Consequences
Each adapter needs a small rules table mapping "detected condition" to
"specific recommended action" plus, where the platform API allows it,
a direct deep link to the relevant settings screen (Android's Settings
intents support this in many cases; macOS is more limited and may only
support opening System Settings to the general Bluetooth pane). This
rules table should live in adapter config, not hardcoded, so new
conflicting apps or OS features discovered post-launch can be added
without a full release — this mirrors the same maintainability
requirement as the known-conflict list in ADR 0010. The recommendation
UI itself (a one-time in-app prompt, not a nagging repeated one) is a
Day 14-16 content/UI task, not a Day 6-9 core-adapter blocker — the
detection logic can ship first and the guided-fix UI can follow once
the underlying signal is proven reliable.
