# Portable AppModel regression harness

`../test_app_model_portable.sh` creates and removes an isolated temporary SwiftPM
package. It copies the **actual** `AppModel`, `DemoFixtures`,
`SessionLifecycleStore`, and `AppModelTests` sources without rewriting them, and
links the repository's `LeapCore` package. Tests inject synthetic sessions,
non-cryptographic fixture signing, in-memory transports, authentication, and
persistence. No vehicle, SMS, or other network request is sent.

These compatibility fixtures exist only to execute orchestration regressions on
Linux. This is **NOT Apple SDK, Combine observation, Keychain, Face ID, WidgetKit,
iOS application build, simulator, or device validation**. Authentication and
Keychain defaults fail closed; widget publication and security-scoped imports
trap if an offline guard regresses. These files must never enter app/widget
targets. Continue to run `validate_macos.sh` on an Apple toolchain for that gate.

Run with Swift 5.9 or newer in `PATH`, or set `SWIFT_BIN` to a Swift executable.
Additional arguments are forwarded to `swift test` (for example, `--filter`).
