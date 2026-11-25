# Release checklist

Use this checklist for every release PR. Record the decisions in the release
PR even when the answer is "not affected" or "no mobile release required."
The goal is to know which existing installations were tested and whether users
must update one app, both peers, or neither.

## What the release workflow publishes

This fork publishes artifacts through GitHub Releases. The Release workflow
runs on `main` and builds when release-please creates a release from a merged
release PR. Ordinary pushes do not open release PRs on this fork.

| App | Target | GitHub release asset |
| --- | --- | --- |
| macOS sender | `OpenSidecarMac` | `OpenDisplay.dmg` |
| macOS receiver | `OpenSidecarMacReceiver` | `OpenDisplayReceiver.dmg` |
| Linux sender (beta) | `linux/crates/od-sender` | `od-sender-{x86_64,aarch64}-unknown-linux-gnu.tar.gz` and checksums |
| Linux receiver (beta) | `linux/crates/od-receiver` | `od-receiver-{x86_64,aarch64}.flatpak` and checksums |
| Android receiver | `Android/` | Signed `OpenDisplay-Android.apk` and checksum |

The macOS apps are built without Developer ID signing or notarization. When
testing a trusted download, try opening it once, then choose **Open Anyway** in
**System Settings → Privacy & Security** if macOS blocks it. See
[Apple's instructions](https://support.apple.com/en-us/102445).

To preview the Finder layout locally, install `dmgbuild==2.0.0` in a Python
3.11+ environment. Run `bash tools/dmg/build.sh path/to/OpenDisplay.app
build/export/OpenDisplay.dmg` with that environment active. Use the receiver
app and `OpenDisplayReceiver.dmg` to preview its disk image.

To recover a partial release, run **Actions → Release → Run workflow** with
the existing tag. The workflow keeps uploaded DMGs and APKs and fills in
missing files. If only the APK checksum is missing, it hashes the uploaded APK.
Enable `rebuild_linux` to replace Linux artifacts and refresh their release
notes. Enable `update_main` to update the Arch package metadata.

## One version for every platform

Every app ships in lockstep under one version: the `vX.Y.Z` tag that
release-please creates. There are no per-platform tags.

- **macOS:** `release.yml` sets `MARKETING_VERSION` from the tag
  (`X.Y.Z`) and the build number from the run number.
- **Linux:** release-please runs in manifest mode
  (`release-please-config.json`, `.release-please-manifest.json`) only so its
  `extra-files` can bump `linux/Cargo.toml` (`[workspace.package] version`)
  and the workspace crates in `linux/Cargo.lock` in the release PR. The
  tagged tree therefore builds with `cargo --locked`, and `linux-release.yml`
  refuses a tag that differs from the workspace version. `od-sender
  --version` and `od-receiver --version` print the tag. The Arch PKGBUILDs
  use the version as `pkgver`; after the release, `arch-bump.yml` (called
  from `release.yml`) runs `linux/packaging/arch/opendisplay-sender/bump.sh
  X.Y.Z` (and the receiver's) and commits the checksum and `.SRCINFO` to
  main.
- **Android**: `versionName` is the tag, see below.

The manifest's version must always be the latest released version. Never edit
it by hand except when bringing this config to a branch: a branch that adds
it must carry the version of the latest `vX.Y.Z` release at merge time (and
`linux/Cargo.toml`/`Cargo.lock` the same), or release-please proposes a
version that already exists.

### Android receiver

The Android build takes `versionName` from the tag without the `v`.
Its `versionCode` is major × 1000000 + minor × 10000 + patch × 100.

The APK uses the fork's signing helper. Its `ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and
`ANDROID_KEY_PASSWORD` secrets take precedence over the repository key.
The repository key is public, so anyone with the key can sign an APK under
that identity. Keep the same signing key to update existing installations.
See [Android signing](Android/release-keystore/README.md).

## Release impact record

Fill this section in and post it as a comment on the release PR before
merging it (release-please rewrites the PR body, so a comment keeps it).
"Changed" means its source or assets changed. "Affected" includes behavior
changed through shared code or a peer's protocol behavior. "Required" means
users need that release to receive the fix or remain compatible.

| App | Changed? | Affected? | Release required? | Reason |
| --- | --- | --- | --- | --- |
| macOS sender | | | | |
| macOS receiver | | | | |
| iPhone receiver | | | | |
| iPad receiver | | | | |
| Android receiver | | | | |

- Minimum useful update combination, such as "sender only" or "both peers":
- User-visible behavior or migration to mention in release notes:

## Compatibility and update order

- [ ] State whether the wire format, discovery, persistence, permissions, or
      saved display identity changed.
- [ ] Record `WireProtocol.version` and `WireProtocol.minSupportedPeer` before
      and after the change.
- [ ] Confirm that new fields and messages are additive and safely ignored by
      released peers, or document the deliberate incompatibility.
- [ ] Test or explicitly reason through every relevant pairing:
  - [ ] new sender with released iPhone/iPad receiver
  - [ ] released sender with new iPhone/iPad receiver
  - [ ] new sender with released macOS receiver
  - [ ] released sender with new macOS receiver
  - [ ] new sender with released Android receiver
  - [ ] released sender with new Android receiver
  - [ ] new sender with new receiver
- [ ] State whether a forced update is required. If yes, explain why graceful
      fallback is impossible and which versions are rejected.
- [ ] When peers must be released together, publish and verify the receiving
      app first. Do not enforce its new minimum version until it is available
      to users.
- [ ] Confirm that upgrading and downgrading preserve existing permissions,
      settings, display arrangement, and pairing state where applicable.

Prefer capability negotiation and fallback over forced updates. A protocol
version bump alone does not require rejecting an older peer; change the minimum
supported peer only when continuing would be incorrect or unsafe.

## Build and automated verification

- [ ] Generate the project from the committed configuration:

  ```sh
  xcodegen generate
  ```

- [ ] Run the macOS unit suite and sender compile check:

  ```sh
  xcodebuild test \
    -project OpenSidecar.xcodeproj \
    -scheme OpenSidecarMac \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
  ```

- [ ] Build the macOS receiver at its macOS 12 deployment floor.
- [ ] Build the generic iOS/iPadOS target. This is required when `Shared/`,
      `iOS/`, protocol code, assets, or project settings changed.
- [ ] Run the Android checks when `Android/` or the wire protocol changed:

  ```sh
  cd Android && ./gradlew testDebugUnitTest lintDebug assembleRelease
  ```
- [ ] For a release candidate, build both macOS apps in Release configuration
      and verify their executables contain `arm64` and `x86_64` with
      `lipo -info` or `file`.
- [ ] Confirm required GitHub checks pass on the final commit.
- [ ] Run `git diff --check` and confirm the working tree is clean.

## End-to-end verification

Choose the rows affected by the release and record the devices, OS versions,
resolution, refresh rate, transport, and app versions used.

- [ ] Extend mode connects, displays changing content, and accepts the cursor.
- [ ] Mirror mode connects and displays changing content.
- [ ] Best, Balanced, and Fast still select valid stream configurations.
- [ ] Rotation or receiver resolution changes reconfigure without stale video.
- [ ] Disconnect, reconnect, receiver quit/reopen, and sleep/wake recover without
      requiring a logout or computer restart.
- [ ] Wi-Fi works with useful frame latency and no unbounded queue growth.
- [ ] iPhone/iPad USB works if sender, transport, framing, or shared receiver
      code changed.
- [ ] Mac-to-Mac Thunderbolt Bridge or Ethernet works if connection migration,
      framing, or transport code changed.
- [ ] Pulling a cable falls back or fails clearly according to the documented
      behavior.
- [ ] The oldest supported macOS receiver launches on Intel hardware when
      receiver or shared code changed.
- [ ] The Android receiver connects over WiFi on a current device and on an
      Android 5.x device or emulator when `Android/` or the protocol changed.
- [ ] Existing App Store iPhone/iPad builds remain usable when no production
      mobile release is planned.

For performance-sensitive changes, compare the same scene before and after.
Record resolution and frame-rate selection, p50/p95 latency, encode time,
delivered FPS, dropped frames, cursor update rate/loss, and subjective behavior.
A clean average does not excuse severe tail latency or recovery failures.

## Packaging and publication

- [ ] Release notes say which apps users need to update and whether mixed
      versions remain supported.
- [ ] Version and build numbers are correct in all generated artifacts.
- [ ] The GitHub release contains both `OpenDisplay.dmg` and
      `OpenDisplayReceiver.dmg`, and the Linux tarballs and Flatpak bundles
      for x86_64 and aarch64 with their `.sha256` files.
- [ ] The release notes end with the "Linux (beta)" section, and
      `od-sender --version` from a tarball prints the release version.
- [ ] Both DMGs mount and the apps launch on a test Mac after local approval.
- [ ] The release contains `OpenDisplay-Android.apk` and its `.sha256`,
      `apksigner verify --print-certs` shows the release certificate (the same
      one as every earlier release), and the APK installs over the previous
      release without uninstalling.
- [ ] Publish user-facing compatibility limits, required update order, known
      issues, and any one-time action users must take.

## After release

- [ ] Repeat one representative new/new connection and one promised mixed-version
      connection using the published binaries.
- [ ] Check logs for connection loops, decode failures, encoder rejection,
      update-feed errors, or permission regressions.
- [ ] Confirm the GitHub release assets show the intended version.
- [ ] Confirm the `bump-arch` job pointed both Arch PKGBUILDs on main at the
      new tag; if it failed, run the "Arch PKGBUILD bump" workflow by hand
      with the tag.
- [ ] Keep the previous release artifacts available as the rollback path and
      document any data or protocol state that prevents a safe downgrade.
