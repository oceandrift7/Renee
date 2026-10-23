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

## Native iOS YouTube Music browser experiment (WKWebView)

An **experimental YouTube Music connection** entry now appears under
**Settings → App Settings** on iOS. Selecting it opens the real
`https://music.youtube.com/` in a new, **ephemeral WKWebView**. Renée does
not spoof the browser user agent, inject login JavaScript, read password
inputs or obtain credentials from Safari.

**Manual iPhone acceptance criteria** (no CI runner can perform Google
login on a user's behalf):

1. Open Settings → App Settings → YouTube Music connection (experimental).
   Confirm the native page loads the actual YouTube Music domain.
2. Try normal interactive sign-in if offered. **If Google refuses embedded
   browser sign-in, report the generic UI refusal**; do not collect
   credentials or spoof the browser to defeat its account restrictions.
3. Only when the top-level page is `https://music.youtube.com`, it exposes
   `ytcfg.LOGGED_IN=true`, a client version, and the browser has a matching
   YouTube-domain signing cookie, tap **Use session**.
4. Confirm that **Not now** retains the browser but persists no secrets.
   **Connect** explicitly allows a one-time handoff of YouTube-domain
   cookies and the signed-in page's public client context to Flutter, which
   checks them and saves them via `flutter_secure_storage` / iOS Keychain.
5. Close/reopen Renée, and verify that the page shows **Session saved on this
   iPhone**. Tap **Disconnect** and verify that Keychain-stored credentials
   are removed. The browser uses non-persistent website data, so no Google
   session cookies are left by this test browser after it is dismissed.
6. Try a public YouTube recording and then an ordinary YouTube Music song.
   Neither the UI, a successful cookie save, nor passing unit tests establishes
   that audio playback works. Record only sanitized error codes, never cookies
   or signed URLs. Finally lock the iPhone and check background buffering.

**Important:** Apple's WKWebView support does not override Google's
embedded OAuth sign-in restrictions. If Google displays
`disallowed_useragent` or denies login, the experiment has found a
platform limitation, not a reason to hard-code a fake browser identity.
Opening Safari is a user convenience; it does *not* transfer Safari's
cookies into Renée. A better, officially supported connection or playback
provider may be required before account streaming can be shipped.

## `LOGIN_REQUIRED` investigation and signed-in session foundations

`LOGIN_REQUIRED` **does not conclusively mean** that a user must type a
password. YouTube sometimes also returns this status for an anonymous
datacenter visitor, an unsupported player identity, or an anti-bot challenge.
Account login and proof-of-origin tokens address different parts of that.

BitChord, Lokal-Konnekt, and LastWave typically extract session cookies plus
the page's `ytcfg` values after an *interactive* signed-in YouTube Music page
has confirmed the selected account; they then make signed `WEB_REMIX`
requests against `music.youtube.com`. They do not just send the Google
account email address or reuse an arbitrary guest visitor ID.

Renée now has an **opt-in session transport foundation**:

- `YouTubeMusicSignedSession` validates session cookie values and creates
  a timestamped, origin-bound `SAPISIDHASH` from the existing signing cookie,
  plus `X-Goog-AuthUser`, `X-Goog-PageId`, and the signed-in visitor identity.
- `YouTubeMusicSessionStore` persists the session only through
  `flutter_secure_storage` (iOS Keychain), not app preferences.
- The direct resolver attempts the authenticated `WEB_REMIX` player first
  if a previously approved session exists, then retains anonymous fallback.
  Signing cookies and Authorization are **never sent to Googlevideo**.
- The actual site's `INNERTUBE_API_KEY` and client version can be bound to the
  session. Tests verify signing and host isolation with fictitious cookies.

**Critical missing piece:** Renée does not yet provide an account connection
screen. Do not present it as an available login feature, and do not request
Google cookies in GitHub issues or ChatGPT. Capturing account cookies carries
substantial account-security risk.

Google explicitly forbids embedded OAuth authorization screens controlled by
the app (e.g. a WKWebView) and may reject them with `disallowed_useragent`.
ASWebAuthenticationSession / official Google Sign-In is safer and supported
for **documented OAuth APIs**, but it does **not** directly hand the app a
YouTube Music browser-cookie session or authorize undocumented audio URLs.
Do not spoof browser identity merely to circumvent Google's sign-in policy.

Before any opt-in sign-in UI is built, independently verify a supported login
and consent flow for the required feature. A valid WEB_REMIX cookie still does
not guarantee that the *media* client can retrieve a playable AAC URL: the
provider may also require PO tokens or decline that track altogether.

## Client-bound Googlevideo headers (BitChord / Lokal-Konnekt lesson)

Some YouTube client identities mint media URLs that can only be fetched with
specific HTTP request headers (especially a matching User-Agent). The iOS
audioplayers plugin cannot attach headers to AVPlayer URL requests. Renée now
includes a small, **127.0.0.1-only** HTTP byte-range relay to preserve those
headers for the chosen signed Googlevideo URL; it streams on demand and does
not write a downloaded song to disk.

The mobile-client resolver verifies the candidate URL with the same media
headers, forwards those headers via the ephemeral `StreamResource`, and the
existing native audio deck connects to the loopback relay when required.
Ordinary header-free streaming and local-library playback do not use it.
The relay accepts only HTTPS `*.googlevideo.com` targets and returns an
opaque local URL that never includes the source's signature or cookies.

- Run `flutter test test/services/streaming/network_audio_header_proxy_test.dart`
  to check forwarded User-Agent / Range, HTTP 206 / Content-Range, revocation,
  and upstream host rejection.
- Repeat a real streaming test on an iPhone. **A green unit test is not
  evidence of successful YouTube playback.**
- Lock the iPhone for a few minutes while a header-bound stream plays: Dart
  loopback servicing in the background is not yet validated. If iOS suspends
  the Dart server, move the relay to a native Swift resource loader instead.
- Restart the app and change tracks; a signed URL and the loopback access
  token must not persist in its library or history.

This independently implements a transport architectural pattern seen in
BitChord and Lokal-Konnekt. No GPL-licensed application code was copied.

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
