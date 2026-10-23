# Renée streaming: what has actually been validated?

This document deliberately separates **code compiling**, **native transport
working**, and **YouTube Music playback working**. None implies the next.

## Automated checks on `dev`

- **Renée streaming checks:** Flutter static analysis and resolver/matching
  tests with HTTP fixtures. No iPhone hardware or live provider is involved.
- **Renée iOS native streaming smoke:** Boots an iPhone *simulator*, builds
  Mornye's Rust/iOS backend and native audio plugin, serves a 60-second silent
  WAV file through a throttled HTTP byte-range server, and checks:
  1. Native AVPlayer actually advances position before the file is fully sent.
  2. Pause stops position advancement.
  3. Resume and seek continue working under constrained throughput.
  4. A measured startup time is logged as `RENEE_STREAM_SMOKE startupMs=...`.
- **Optional live YouTube resource test:** Only runs when someone manually
  supplies a publicly playable video ID through the workflow-dispatch form.
  Its success requires the experimental provider resolver to return a valid
  HTTPS audio URL **and** native playback position to advance. A failed resolve
  is reported as a failure, not counted as successful playback.
- **Unsigned dev IPA:** The same macOS workflow attempts an unsigned iOS
  release build and uploads `Renee-dev-unsigned-ipa` as an artifact. An artifact
  exists only if the build succeeded. It must be signed before installation.
  This is a test build, not a published release.

The simulator cannot prove physical-device network resilience, audio-route
switching, lock-screen controls, or performance on Libyan carrier networks.

## Running the simulator validation on GitHub

1. Open the repository's **Actions** tab.
2. Select **Renée iOS native streaming smoke**.
3. Choose **Run workflow** on the **dev** branch.
4. Leave the optional video ID empty for the repeatable local-network native
   smoke test. To additionally test live provider access, supply an 11-character
   ID for a public recording you are authorized to stream.
5. Open the run and inspect each step. The unsigned IPA is found under
   **Artifacts** if the release build step succeeded.

GitHub macOS CI requires time and may fail for infrastructure or dependency
reasons. A run is not a pass until GitHub marks it successful.

## Checking an iPhone build

An unsigned IPA needs to be signed and installed with your own signing method
before it can run on an iPhone. A successful build does **not** prove streaming
works. With a signed test build, check the following with at least two songs:

- Play a locally downloaded track while offline.
- With Wi-Fi connected, press the separate experimental online Play button for
  a public, freely playable track. Note whether the intended recording plays.
- Measure tap-to-audible-sound, not tap-to-loading-spinner or API response.
- Switch to another song while the first is loading. The old result must not
  hijack the new selection.
- Test cellular data or a genuinely weak connection and record stall count,
  stall durations, and whether playback resumes automatically.
- Lock the phone, wait, then pause, resume, skip and seek using lock-screen or
  headphone controls.
- Test airplane mode only for a track already in local storage. Do not claim
  that online playback supports offline access.

Record the iPhone model, iOS version, song, network type, observed startup
time, stall count, and any error message. **Never share signed stream URLs,
authentication headers, session tokens, or accounts** in public issues.

## Current limitations

The YouTube Music resolver uses an undocumented endpoint and may return no
usable audio URL, depending on availability, rights, network or provider
changes. Renée currently prefers about 128 kbps AAC and rejects 48 kbps audio;
96 kbps is the configured minimum if offered. It cannot manufacture AAC
formats that the provider does not expose.

A successful synthetic-network test confirms the native transport works under
that particular simulated condition. It does **not** verify any specific
YouTube Music song, subscription right, or reliable real-world Spotify-level
performance.
