// Test-only, fail-closed Linux adapters. No Apple implementation is exercised.
// The portable harness copies these into its temporary package, never the app.
import Foundation
import LeapCore

struct KeychainStore {
    func load<T: Decodable>(_ type: T.Type, account: String) throws -> T? { throw StoreError.unavailable }
    func save<T: Encodable>(_ value: T, account: String) throws { throw StoreError.unavailable }
    func remove(account: String) throws { throw StoreError.unavailable }

    enum StoreError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Keychain is unavailable in portable tests; inject fixture persistence." }
    }
}

@MainActor
struct LocalControlAuthentication {
    func verify() async throws { throw AuthenticationError.unavailable }
    enum AuthenticationError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Local authentication is unavailable in portable tests; inject fixture authentication." }
    }
}

@MainActor
final class WidgetSnapshotPublisher {
    init() { preconditionFailure("Offline tests must not instantiate the widget publisher") }
    func beginSession(generation: UUID, source: WidgetSnapshot.Source) throws { unavailable() }
    func publish(status: VehicleStatus, generation: UUID) throws { unavailable() }
    func markRefreshFailed(generation: UUID) throws { unavailable() }
    func clear() throws { unavailable() }
    private func unavailable() -> Never { preconditionFailure("Offline tests must not publish widget data") }
}

extension URL {
    func startAccessingSecurityScopedResource() -> Bool {
        preconditionFailure("Offline tests must not import security-scoped files")
    }
    func stopAccessingSecurityScopedResource() {
        preconditionFailure("Offline tests must not import security-scoped files")
    }
}
