# HANDOFF: automated release workflow (#153, part 2 of 2)

## What was done

Added `.github/workflows/release-android.yml`: builds a signed Android
App Bundle on a `v*` tag push (or `workflow_dispatch`), verifies it is
actually signed, and attaches it to a draft GitHub Release for manual
upload to Play Console.

Part 1 (#154) made `versionCode` read `THRW_VERSION_CODE`; this is what
supplies it. Separate PRs because `.github/**` is always human-merge per
AGENTS.md while `packages/**` auto-merges - bundling them would have
dragged the Gradle change into the human-merge lane for no reason.

## Secrets Tom needs to add before the first run

Four repository secrets. The keystore is binary, so it goes in base64:

```
# from the machine holding the upload key
base64 -i ~/Documents/thrw-upload.jks | pbcopy
gh secret set THRW_PLAY_KEYSTORE_BASE64 --repo thrwapp/thrw   # paste

gh secret set THRW_PLAY_KEYSTORE_PASSWORD --repo thrwapp/thrw
gh secret set THRW_PLAY_KEY_ALIAS      --repo thrwapp/thrw    # thrw-signing-key
gh secret set THRW_PLAY_KEY_PASSWORD   --repo thrwapp/thrw
```

Each prompts for the value rather than taking it as an argument, so
nothing lands in shell history.

## Design decisions

**Build-only, not auto-upload to Play.** Decided with Tom. Pushing to a
Play track needs a Google Cloud service account with Play Console
access plus a third-party action; not worth the dependency until
releases are frequent enough that manual upload is a real chore.

**`versionCode` from commit count, not `github.run_number`.** The run
number resets to 1 if this workflow file is renamed or recreated, which
would silently collide with values Play has already burned permanently.
Commit count is reproducible locally (`git rev-list --count HEAD`),
strictly increasing, and traces back to a specific commit. Requires
`fetch-depth: 0` - a shallow clone computes it *wrong and low*, which
is the dangerous direction.

**Signature verified explicitly, not inferred from a green build.**
This is the important one. `bundleRelease` succeeding proves nothing
about signing: an unconfigured build succeeds and produces an unsigned
bundle *by design* (see `app/build.gradle.kts`, and
`docs/handoffs/148.md` for why that's deliberate). So a mistyped secret
would otherwise sail through CI and only fail hours later when Play
rejects the upload. The workflow asserts a certificate is present and
fails loudly if not.

**Android SDK installed by hand, copied from `ci.yml`'s `android` job.**
Same reasoning as there: it pins the exact platform/build-tools versions
`app/build.gradle.kts` declares rather than trusting a third-party
setup action's defaults, and avoids a new dependency (AGENTS.md).
Downside noted below.

**Keystore deleted with `if: always()`**, so key material never
outlives the job even when the build fails.

## Known gaps / judgment calls

- **The SDK install block is now duplicated** between `ci.yml` and this
  workflow. Deliberate for now - a composite action would be the DRY
  fix, but that's a new `.github/actions/` structure for two call
  sites. The real cost is that changing `compileSdk` or `build-tools`
  means updating *both*; both copies carry a comment saying so.
- **Untested end-to-end.** The workflow has never run - it cannot until
  the four secrets exist, and it can't be meaningfully dry-run locally.
  The YAML was parsed and structurally validated (10 steps, correct
  triggers and permissions), and every individual command in it was
  verified by hand while building #150/#154, but the assembled whole is
  unproven. First `workflow_dispatch` run is the real test; expect to
  need a fixup PR.
- **The Release is created as a draft**, so a tag push never publishes
  anything user-visible by accident. Publishing is a deliberate click.
- **No `versionName` automation** - see #154's handoff for why that
  stays a human decision per release.
