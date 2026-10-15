<!-- CODEGRAPH_START -->

## CodeGraph

If a `.codegraph/` directory exists at the repository root, use CodeGraph before
`rg`, `find`, or direct source reading when locating code or understanding call
paths. Otherwise use normal repository inspection tools.

<!-- CODEGRAPH_END -->

# LeapAuto Repository Instructions

## Project Profile

LeapAuto is an unofficial, personal-use native iOS client for verified Zero Run
China App vehicle-status and remote-control flows. The maintained application is
the SwiftUI project in `ios/`; the former Android application and its build and
release tooling have been removed. Android implementation history remains in Git.

The implementation, tests, and verified protocol documentation in `API/` are the
authority for behavior. Read `ios/README.md`, `ios/docs/FEATURE-MATRIX.md`, and
`ios/docs/PLATFORM-GATES.md` before planning feature work. Do not describe a planned,
offline-only, or platform-gated feature as available on an iPhone. Linux parsing
and portable tests do not establish an Apple SDK build or real-device behavior.

The root `README.md` intentionally contains only the original disclaimer and
“许可与责任声明”. Preserve both verbatim; keep development instructions and
feature documentation under `ios/`.

## Repository Map

- `ios/LeapAuto.xcodeproj/`: checked-in Xcode project and shared scheme.
- `ios/LeapAuto/App/`: app lifecycle, session and selected-vehicle state, demo
  fixtures, refresh and command orchestration.
- `ios/LeapAuto/Views/`: SwiftUI screens, confirmation flows, and shared design
  system.
- `ios/LeapAuto/Security/`: Keychain, local authentication, and session lifecycle.
- `ios/LeapAuto/Bluetooth/`: Apple Bluetooth transport and platform safety gates.
- `ios/Packages/LeapCore/`: platform-independent API, signing, protocol, models,
  telemetry, command and result handling, plus offline XCTest coverage.
- `ios/LeapAutoWidget/` and `ios/Shared/`: WidgetKit extension and minimal protected
  local snapshot sharing.
- `ios/LeapAutoTests/` and `ios/LeapAutoUITests/`: app and UI regression tests.
- `ios/scripts/`: structure validation, Xcode-project generation, portable tests,
  and macOS build/test entrypoints.
- `ios/docs/`: implementation scope, platform requirements, verification evidence,
  limitations, and attribution.
- `API/`: verified API/BLE specifications, third-party protocol references and
  synthetic offline fixtures. These are shared migration references, not Android
  application dependencies.
- `design/`: historical visual specifications. Preserve their visual and safety
  intent; Android-specific Compose examples are reference material, not iOS build
  requirements. Use the current SwiftUI design system for implementation.
- `artifacts/`: existing icon and historical visual-reference assets. A historical
  screenshot is not evidence of the current iOS UI.

## API and Protocol Knowledge Base

Search `API/` before researching or modifying an endpoint, telemetry signal,
command payload, cryptographic operation, or protocol flow. `API/API.md` and the
BLE documents record verified protocol facts. Preserve third-party reference
libraries, their attribution, and their licenses. Do not delete a reference merely
because it describes the official Android app or uses another language.

Unknown signal IDs, vehicle capabilities, and response values remain unknown.
Do not convert a speculative mapping into user-facing status or a control command.
When a signal or command is verified, update the relevant LeapCore model/parser or
builder, the consuming UI/feedback behavior, tests, and protocol documentation
together. Coordinate changes to shared protocol and state files with affected
feature owners. Use synthetic fixtures and redact captured evidence.

## Safety and Data Boundaries

- Never send a real vehicle command, SMS, network login, payment, navigation or
  external location request as a test without explicit user authorization. Use
  offline fixtures, mock transports, or pure request construction instead.
- A successful HTTP POST means the service accepted a request. Only verified
  command-result evidence or a later vehicle-state refresh supports completion.
  Preserve distinct pending, timeout, unknown, failure, and completion states.
- Preserve operation-password, local device authentication, driving-state,
  freshness, capability, confirmation and session-generation gates. Do not bypass
  a missing SDK, credential, verified backend, or hardware gate with fake values.
- Do not automatically retry a vehicle-control POST after a timeout or uncertain
  response. Polling for a result must not cause a second control submission.
- Never log or commit tokens, refresh credentials, operation PINs, phone numbers,
  VINs, raw account/vehicle responses, precise coordinates, signing credentials,
  SDK secrets, API keys, or real certificate/private-key material.
- Keep session credentials in device-only protected Keychain storage. Do not move
  them into UserDefaults, shared widget storage, source files, or diagnostics.
  Operation passwords must remain transient unless an explicitly approved secure
  storage design is implemented and tested.
- Preserve logout invalidation and cleanup behavior, including pending-response
  rejection and visible retry on local cleanup failure. Stale responses must not
  restore a logged-out session or another selected vehicle's state.
- Do not persist raw coordinates or reverse-geocoded addresses. Vehicle location
  remains in memory; do not add background tracking, geocoding, location sharing,
  or external-map handoff implicitly. Do not infer a WGS-84/GCJ-02 conversion
  without a verified protocol contract and regression tests.
- Keep widget snapshots minimal, anonymous, protected, backup-excluded and subject
  to expiry. Do not include account IDs, VINs, credentials, PINs, or coordinates.
  Preserve the explicit distinction between demo data and real telemetry.
- Real Bluetooth hardware, background modes, Apple capabilities, SDK integration,
  and new persistent access require their own verified implementation and
  authorization. Offline protocol tests do not authorize enabling hardware.
- Preserve privacy consent and explicit-copy boundaries. Debug views must not
  collect or retain real account/vehicle data as repository fixtures.

## UI and Design

Use the shared SwiftUI design system and consult `design/` for the visual intent:
restrained translucent information surfaces, stable touch targets, clear text,
light/dark consistency, Leap Blue `#0066FF`, Energy Green `#00C853`, and Alert Red
`#FF3B30`. Safety states need text or icons in addition to color. Maintain strong
contrast in confirmation dialogs and password entry, including accessibility
settings. Preserve disabled, loading, error, biometric and result feedback.

Do not introduce heavy blur dependencies, distracting gradients, unlicensed
vehicle imagery, copied branding/screenshots, or marketing UI that competes with
vehicle state. Do not impose Android-only units, Compose APIs, or APK size gates
on the iOS implementation.

## Build and Test

Run from the repository root:

```sh
./ios/scripts/validate.sh
swift test --package-path ios/Packages/LeapCore
```

On a Mac with Xcode and an available supported iPhone simulator, run:

```sh
./ios/scripts/validate_macos.sh
```

After adding or removing Swift source files, regenerate and validate the checked-in
project with `python3 ios/scripts/generate_project.py`. Never edit generated build
output in `.build/`, `DerivedData/`, or `build/`.

Every new feature requires tests for normal, boundary and failure paths. Every
modified feature requires checking and updating existing regression coverage. Run
the relevant tests while developing and the full applicable test suite before
delivery packaging or publication. A failing or unexecuted required suite blocks
release. A portable test substitute must be labeled as such; do not claim Apple
CryptoKit, Security, SwiftUI, WidgetKit, Face ID, simulator or iPhone coverage when
only Linux tools were available. Builds do not replace device inspection or
owner-authorized real-vehicle acceptance.

## Collaboration, Authorization and Release

The project coordinator owns scope and handoffs. Assign non-overlapping specialist
work for app/UI, protocol/data, security, Bluetooth, widgets and tests. Clarify
requirements, privacy boundaries and acceptance criteria before implementation
when they are unclear. Testing evidence does not itself grant product acceptance
or permission to publish.

For a user asking why behavior occurs or reporting a real-vehicle issue, investigate
and explain the evidence and root cause first. Present the proposed change and
impact, then obtain agreement before modifying behavior. An explicit request to
implement a specified change authorizes the requested implementation and offline
validation; it does not authorize unrelated real operations or publication.

Packaging is user-triggered only. Finishing implementation, documentation, tests or
acceptance does not authorize creating a signed distribution or publishing one.
Confirm the intended iOS distribution destination and required signing setup when
the user requests release; there is no Android/PGYER default in this repository.
Keep Apple signing certificates, private keys and provisioning profiles local or
in approved secrets storage. Do not create accounts, change capabilities, purchase
memberships or publish builds without the required explicit authorization.

Before a requested release, require implementation evidence, full applicable test
results, product acceptance, consistent version/build metadata and current release
notes. Release notes contain only the changes actually made in that version, use
numbered items on separate lines, and must not recycle historical notes. Verify
the actual signed artifact and authorized destination rather than assuming a
successful build means successful publication.

## Code Style and Handoff

Follow existing Swift conventions: four-space indentation, immutable-first state,
small focused types/views, `PascalCase` types and `camelCase` members. Preserve
actor/thread isolation and explicit cancellation/session boundaries.

Every implementation handoff includes:

1. Changed files and affected ownership boundaries.
2. Behavior and security impact, especially PIN, biometrics, location and control.
3. Commands run and observed outcomes, including skipped tests.
4. Simulator/device evidence, or a clear statement that it was unavailable.
5. Defects, residual risks, platform blockers and unexecuted coverage.

Keep commits scoped with concise imperative messages, preferably Chinese for
delivery work. Do not reset or discard unrelated user changes. Do not commit or
push unless the current task authorizes it.
