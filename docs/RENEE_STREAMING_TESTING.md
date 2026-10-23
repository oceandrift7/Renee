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
- **Live public YouTube playback check:** On a push, runs against an ordinary
  public short video (`jNQXAC9IVRw`) rather than a commercial music track.
  Manual workflow-dispatch runs can supply a different public video ID. It
  requires an independently verified HTTPS audio URL **and** advancing native
  playback. This step has a 20-minute wall-clock cap and is **not** ignored
  after failure. Passing it does not prove arbitrary YouTube Music songs play.
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
4. Leave the optional video ID empty for only the local synthetic-network
   smoke test, or supply an 11-character ID for a public recording you are
   authorized to stream. Push-triggered runs also exercise one public YouTube
   clip. The live check may fail because GitHub's datacenter IP is challenged
   even when the recording is accessible from a consumer device.
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

The YouTube Music resolver uses undocumented playback endpoints and may
return no usable audio URL, depending on availability, rights, network or
provider changes. The current anonymous client cascade includes an embedded
client that only supports embeddable recordings; this is no substitute for
proper access authorization, cipher support, or provider-required PO tokens. Renée currently prefers about 128 kbps AAC and rejects 48 kbps audio;
96 kbps is the configured minimum if offered. It cannot manufacture AAC
formats that the provider does not expose.

A successful synthetic-network test confirms the native transport works under
that particular simulated condition. It does **not** verify any specific
YouTube Music song, subscription right, or reliable real-world Spotify-level
performance.
