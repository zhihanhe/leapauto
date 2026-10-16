import XCTest
@testable import LeapCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Deliberately non-cryptographic fixture signer, injected only by this test target.
private struct FixtureCryptography: ProtocolCryptography {
    func md5Short(_ value: String) throws -> String { "fixture-md5" }
    func sha256Hex(_ value: String) throws -> String { "fixture-sha256" }
    func hmacSHA256Hex(key: Data, value: String) throws -> String { "fixture-hmac" }
    func encryptOperationPIN(_ pin: String, token: String) throws -> String { "fixture-ciphertext" }
    func rsaEncryptPhone(_ phone: String) throws -> String { "fixture-phone-ciphertext" }
}

private actor FixtureTransport: HTTPTransport {
    enum Reply: Sendable { case json(String, Int = 200), error(LeapAPIError), cancelled, redirected(String) }
    var replies: [Reply]
    var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func execute(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        guard !replies.isEmpty else { throw LeapAPIError.invalidResponse }
        switch replies.removeFirst() {
        case .json(let text, let status): return HTTPResult(statusCode: status, body: Data(text.utf8), responseURL: request.url)
        case .error(let error): throw error
        case .cancelled: throw CancellationError()
        case .redirected(let address): return HTTPResult(statusCode: 200, body: Data("{\"code\":0}".utf8), responseURL: URL(string: address))
        }
    }
    func count() -> Int { requests.count }
    func commandCount() -> Int { requests.filter { $0.url?.path == "/app/app-control-service/v3/api/appremotectl" }.count }
    func allRequests() -> [URLRequest] { requests }
}

private actor SuspendedTransport: HTTPTransport {
    let firstResponse: String?
    var requests: [URLRequest] = []
    var continuation: CheckedContinuation<HTTPResult, Error>?
    var startWaiters: [CheckedContinuation<Void, Never>] = []
    init(firstResponse: String? = nil) { self.firstResponse = firstResponse }
    func execute(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        if requests.count == 1, let firstResponse {
            return HTTPResult(statusCode: 200, body: Data(firstResponse.utf8), responseURL: request.url)
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            startWaiters.forEach { $0.resume() }; startWaiters = []
        }
    }
    func waitUntilSuspended() async {
        if continuation != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func complete(_ response: String) {
        continuation?.resume(returning: HTTPResult(statusCode: 200, body: Data(response.utf8), responseURL: requests.last?.url))
        continuation = nil
    }
    func commandCount() -> Int { requests.filter { $0.url?.path == "/app/app-control-service/v3/api/appremotectl" }.count }
    func allRequests() -> [URLRequest] { requests }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date = date.addingTimeInterval(seconds) }
}

final class APIClientTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private func session(expiry: Date? = nil) -> Session {
        // Synthetic values constructed at runtime; never real account credentials.
        Session(deviceID: String(repeating: "d", count: 32), clientPlatform: .android,
                oldAuth: LegacyAuth(accountID: "fixture-account", token: String(repeating: "o", count: 32)),
                newAuth: GatewayAuth(accountID: "fixture-account", accessToken: String(repeating: "g", count: 80),
                                     refreshToken: String(repeating: "r", count: 32), signKey: Data([1, 2, 3]), expiresAt: expiry),
                selectedVIN: "FIXTUREVIN0000001", selectedCarType: "C16", route: RouteData(appRegion: TrustedEndpoints.global))
    }
    private var parked: String { "{\"code\":0,\"data\":{\"signalMap\":{\"gearStatus\":\"P\",\"speed\":0,\"sts\":1800000000000,\"soc\":70}}}" }
    private func client(_ transport: any HTTPTransport, session: Session? = nil) -> LeapAPI {
        let time = instant
        return LeapAPI(session: session ?? self.session(), transport: transport, crypto: FixtureCryptography(), now: { time })
    }

    private func gatewayReply() throws -> (json: String, access: String) {
        func url64(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        let payload = try JSONValue.object(["exp": .number(1_800_003_600), "user_name": .string("deviceId:" + String(repeating: "b", count: 32))]).encodedData()
        let token = "fixture." + url64(payload) + "." + url64(Data([3, 4, 5, 6]))
        let root: JSONValue = .object(["code": .number(0), "data": .object([
            "accountId": .string("gateway-different-account"), "accessToken": .string(token),
            "refreshToken": .string(String(repeating: "n", count: 32)),
            "signParam": .object(["r2": .string(Data([1, 2, 3, 4]).base64EncodedString()),
                                  "r3": .string(Data([5, 6, 7, 8]).base64EncodedString())])
        ])])
        return (String(decoding: try root.encodedData(), as: UTF8.self), token)
    }

    func testConnectionConfigurationUsesReadOnlyBoundRequest() async throws {
        let transport = FixtureTransport([.json("{\"code\":0,\"data\":{\"vin\":\"FIXTUREVIN0000001\",\"config\":{\"4\":{\"mac\":\"12:34:56:78:9A:BC\",\"version\":\"fixture-v1\"}}}}")])
        let api = client(transport)
        let configuration = try await api.connectionConfiguration()
        XCTAssertTrue(configuration.hasBluetoothConfiguration)
        XCTAssertEqual(configuration.controllerVersion, "fixture-v1")
        let requests = await transport.allRequests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "appgateway.leapmotor.com")
        XCTAssertEqual(request.url?.path, "/carownerservice/v3/api/vehicleinfo/commonConfig")
        XCTAssertNil(request.httpBody)
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "vin" })?.value, "FIXTUREVIN0000001")
        XCTAssertEqual(query.first(where: { $0.name == "osType" })?.value, "Android")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "sign"))
        let commandCount = await transport.commandCount()
        XCTAssertEqual(commandCount, 0)
    }

    func testConnectionConfigurationRejectsAnotherVehicle() async throws {
        let transport = FixtureTransport([.json("{\"code\":0,\"data\":{\"vin\":\"ANOTHERVEHICLE001\",\"config\":{}}}")])
        do { _ = try await client(transport).connectionConfiguration(); XCTFail("Wrong vehicle must fail") }
        catch { XCTAssertEqual(error as? LeapAPIError, .invalidResponse) }
    }

    func testConnectionConfigurationRejectsMismatchedAccountWithoutRequest() async throws {
        var candidate = session()
        candidate.newAuth?.accountID = "different-account"
        let transport = FixtureTransport([])
        do { _ = try await client(transport, session: candidate).connectionConfiguration(); XCTFail("Identity must match") }
        catch { XCTAssertEqual(error as? LeapAPIError, .invalidSession) }
        let count = await transport.count()
        XCTAssertEqual(count, 0)
    }

    func testRefreshVehicleMetadataRetainsC10CapabilitiesWithoutSwitchingVehicle() async throws {
        let transport = FixtureTransport([.json("{\"code\":0,\"data\":[{\"vin\":\"FIXTUREVIN0000001\",\"carType\":\"C10\",\"funcConfig\":{\"HVAC\":{\"supported\":true}}}]}")])
        let api = client(transport)
        let vehicle = try await api.refreshSelectedVehicleMetadata()
        XCTAssertEqual(vehicle.modelName, "C10")
        XCTAssertEqual(vehicle.capabilities[.hvac], .supported)
        let snapshot = await api.snapshot()
        XCTAssertEqual(snapshot.selectedVIN, "FIXTUREVIN0000001")
        XCTAssertEqual(snapshot.selectedCarType, "C10")
    }

    func testRefreshMetadataCannotSilentlyReplaceMissingVehicle() async throws {
        let transport = FixtureTransport([.json("{\"code\":0,\"data\":[{\"vin\":\"OTHERFIXTUREVIN01\",\"carType\":\"C10\"}]}")])
        let api = client(transport)
        do { _ = try await api.refreshSelectedVehicleMetadata(); XCTFail("Must not select another vehicle") }
        catch { XCTAssertEqual(error as? LeapAPIError, .unknownVehicle) }
        let snapshot = await api.snapshot()
        XCTAssertEqual(snapshot.selectedVIN, "")
        XCTAssertEqual(snapshot.selectedCarType, "")
        XCTAssertNil(snapshot.route)
        let metadata = await api.vehicleMetadataSnapshot()
        XCTAssertEqual(metadata.map(\.vin), ["OTHERFIXTUREVIN01"])
    }

    func testMetadataSnapshotReplacesCompleteListWithoutChangingSelection() async throws {
        let first = #"{"code":0,"data":[{"vin":"FIXTUREVIN0000001","carType":"C10","funcConfig":{"HVAC":{"supported":true}}},{"vin":"OTHERFIXTUREVIN01","carType":"C16"}]}"#
        let next = #"{"code":0,"data":[{"vin":"NEWFIXTUREVIN001","carType":"C11"},{"vin":"FIXTUREVIN0000001","carType":"C10","funcConfig":{"HVAC":{"supported":false}}}]}"#
        let transport = FixtureTransport([.json(first), .json(next)])
        let api = client(transport)
        let empty = await api.vehicleMetadataSnapshot()
        XCTAssertTrue(empty.isEmpty)
        _ = try await api.refreshSelectedVehicleMetadata()
        let previous = await api.vehicleMetadataSnapshot()
        let selected = try await api.refreshSelectedVehicleMetadata()
        let updated = await api.vehicleMetadataSnapshot()
        let snapshot = await api.snapshot()
        XCTAssertEqual(previous.map(\.vin), ["FIXTUREVIN0000001", "OTHERFIXTUREVIN01"])
        XCTAssertEqual(updated.map(\.vin), ["NEWFIXTUREVIN001", "FIXTUREVIN0000001"])
        XCTAssertEqual(updated.last, selected)
        XCTAssertEqual(selected.capabilities[.hvac], .unsupported)
        XCTAssertEqual(snapshot.selectedVIN, "FIXTUREVIN0000001")
        XCTAssertNotNil(snapshot.route)
        let requests = await transport.allRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.path == "/app/app-global-service/v1/vehicle/list" })
    }

    func testRemovedMetadataInvalidatesTelemetryAndStopsFurtherVehicleReads() async throws {
        let transport = FixtureTransport([.json(parked), .json(#"{"code":0,"data":[]}"#)])
        let api = client(transport)
        _ = try await api.refreshStatus()
        do { _ = try await api.refreshSelectedVehicleMetadata(); XCTFail("Selected vehicle was removed") }
        catch { XCTAssertEqual(error as? LeapAPIError, .unknownVehicle) }
        let metadata = await api.vehicleMetadataSnapshot()
        XCTAssertTrue(metadata.isEmpty)
        do { _ = try await api.refreshStatus(); XCTFail("No stale selected VIN may be queried") }
        catch { XCTAssertEqual(error as? LeapAPIError, .noVehicle) }
        do { _ = try await api.connectionConfiguration(); XCTFail("No stale selected VIN may be queried") }
        catch { XCTAssertEqual(error as? LeapAPIError, .noVehicle) }
        do { _ = try await api.pollResult(messageID: "fixture-result"); XCTFail("No stale selected VIN may be queried") }
        catch { XCTAssertEqual(error as? LeapAPIError, .noVehicle) }
        do { _ = try await api.send(command: .lock, pin: "0000"); XCTFail("Telemetry for removed vehicle must be discarded") }
        catch { XCTAssertEqual(error as? CommandValidationError, .noVehicleStatus) }
        let requests = await transport.count()
        XCTAssertEqual(requests, 2, "Revoked selection must fail locally")
    }

    func testMalformedVehicleListsPreserveSelectionAndLastSuccessfulMetadata() async throws {
        let valid = #"{"code":0,"data":[{"vin":"FIXTUREVIN0000001","carType":"C10","funcConfig":{"HVAC":{"supported":true}}}]}"#
        let malformed = [
            #"{"code":0}"#,
            #"{"code":0,"data":null}"#,
            #"{"code":0,"data":{}}"#,
            #"{"code":0,"data":{"vehicles":[{"vin":"FIXTUREVIN0000001"}]}}"#,
            #"{"code":0,"data":[null]}"#,
            #"{"code":0,"data":["FIXTUREVIN0000001"]}"#,
            #"{"code":0,"data":[{"vin":1234567890}]}"#,
            #"{"code":0,"data":[{"vin":"short"}]}"#,
            #"{"code":0,"data":[{"vin":"FIXTUREVIN0000001"},{"vin":"invalid value"}]}"#,
            #"{"code":0,"data":[{"funcConfig":{"HVAC":{"vin":"FIXTUREVIN0000001"}}}]}"#,
            #"{"code":0,"data":[{"vin":"FIXTUREVIN0000001"},{"vin":"FIXTUREVIN0000001"}]}"#,
            #"{"code":0,"data":[{"vin":"FIXTUREVIN0000001","isOwner":true},{"vin":"FIXTUREVIN0000001","isOwner":false}]}"#
        ]
        for response in malformed {
            let transport = FixtureTransport([.json(valid), .json(response)])
            let api = client(transport)
            _ = try await api.refreshSelectedVehicleMetadata()
            let before = await api.snapshot()
            let metadataBefore = await api.vehicleMetadataSnapshot()
            do { _ = try await api.refreshSelectedVehicleMetadata(); XCTFail("Malformed list must not imply removal") }
            catch { XCTAssertEqual(error as? LeapAPIError, .invalidResponse) }
            let after = await api.snapshot()
            let metadataAfter = await api.vehicleMetadataSnapshot()
            XCTAssertEqual(after, before)
            XCTAssertEqual(metadataAfter, metadataBefore)
        }
    }

    func testVehicleListIgnoresNestedVINsAndPreservesTopLevelOrder() async throws {
        let response = #"{"code":0,"data":[{"vin":"FIXTUREVIN0000001","carType":"C10","funcConfig":{"HVAC":{"supported":true,"vin":"NESTEDFIXTUREVIN1"}}},{"vin":"OTHERFIXTUREVIN01","carType":"C11"}]}"#
        let transport = FixtureTransport([.json(response)])
        let api = client(transport)
        let selected = try await api.refreshSelectedVehicleMetadata()
        let metadata = await api.vehicleMetadataSnapshot()
        XCTAssertEqual(metadata.map(\.vin), ["FIXTUREVIN0000001", "OTHERFIXTUREVIN01"])
        XCTAssertEqual(selected.modelName, "C10")
        XCTAssertEqual(selected.capabilities[.hvac], .supported)
        do { try await api.selectVehicle(Vehicle(vin: "NESTEDFIXTUREVIN1")); XCTFail("Nested VIN is not a vehicle") }
        catch { XCTAssertEqual(error as? LeapAPIError, .unknownVehicle) }
        let count = await transport.count()
        XCTAssertEqual(count, 1)
    }

    func testVehicleMetadataNetworkFailureKeepsPriorSnapshot() async throws {
        let valid = #"{"code":0,"data":[{"vin":"FIXTUREVIN0000001","carType":"C10"}]}"#
        let transport = FixtureTransport([.json(valid), .error(.networkUnavailable)])
        let api = client(transport)
        _ = try await api.refreshSelectedVehicleMetadata()
        let before = await api.snapshot()
        let metadataBefore = await api.vehicleMetadataSnapshot()
        do { _ = try await api.refreshSelectedVehicleMetadata(); XCTFail("Expected read failure") }
        catch { XCTAssertEqual(error as? LeapAPIError, .networkUnavailable) }
        let after = await api.snapshot()
        let metadataAfter = await api.vehicleMetadataSnapshot()
        XCTAssertEqual(after, before)
        XCTAssertEqual(metadataAfter, metadataBefore)
    }

    func testRemovedMetadataStillCommitsRotatedCredentials() async throws {
        let reply = try gatewayReply()
        let transport = FixtureTransport([.json(reply.json), .json(#"{"code":0,"data":[]}"#)])
        let api = client(transport, session: session(expiry: instant.addingTimeInterval(30)))
        do { _ = try await api.refreshSelectedVehicleMetadata(); XCTFail("Selected vehicle was removed") }
        catch { XCTAssertEqual(error as? LeapAPIError, .unknownVehicle) }
        let after = await api.snapshot()
        XCTAssertEqual(after.newAuth?.accessToken, reply.access)
        XCTAssertEqual(after.deviceID, String(repeating: "b", count: 32))
        XCTAssertEqual(after.selectedVIN, "")
        XCTAssertEqual(after.selectedCarType, "")
        XCTAssertNil(after.route)
    }

    func testLogoutDiscardsInflightVehicleMetadata() async throws {
        let transport = SuspendedTransport()
        let api = client(transport)
        let refresh = Task { try await api.refreshSelectedVehicleMetadata() }
        await transport.waitUntilSuspended()
        await api.logout()
        await transport.complete(#"{"code":0,"data":[{"vin":"FIXTUREVIN0000001","carType":"C10"}]}"#)
        do { _ = try await refresh.value; XCTFail("Metadata cannot restore a logged out session") }
        catch { XCTAssertEqual(error as? LeapAPIError, .sessionChanged) }
        let after = await api.snapshot()
        let metadata = await api.vehicleMetadataSnapshot()
        XCTAssertFalse(after.isAuthenticated)
        XCTAssertEqual(after.selectedVIN, "")
        XCTAssertTrue(metadata.isEmpty)
    }

    func testCancelledVehicleMetadataDoesNotRevokeSelectionOrReplaceCache() async throws {
        let initial = #"{"code":0,"data":[{"vin":"FIXTUREVIN0000001","carType":"C10"}]}"#
        let transport = SuspendedTransport(firstResponse: initial)
        let api = client(transport)
        _ = try await api.refreshSelectedVehicleMetadata()
        let before = await api.snapshot()
        let metadataBefore = await api.vehicleMetadataSnapshot()
        let refresh = Task { try await api.refreshSelectedVehicleMetadata() }
        await transport.waitUntilSuspended()
        refresh.cancel()
        await transport.complete(#"{"code":0,"data":[]}"#)
        do { _ = try await refresh.value; XCTFail("Cancelled metadata cannot remove selected vehicle") }
        catch { XCTAssertTrue(error is CancellationError) }
        let after = await api.snapshot()
        let metadataAfter = await api.vehicleMetadataSnapshot()
        XCTAssertEqual(after, before)
        XCTAssertEqual(metadataAfter, metadataBefore)
    }

    func testBootstrapRejectsUnknownListEnvelopeWithoutClearingSelection() async throws {
        let transport = FixtureTransport([.json(#"{"code":0,"data":{}}"#)])
        let api = client(transport)
        let before = await api.snapshot()
        do { _ = try await api.bootstrap(); XCTFail("Unknown list envelope must not clear selection") }
        catch { XCTAssertEqual(error as? LeapAPIError, .invalidResponse) }
        let after = await api.snapshot()
        XCTAssertEqual(after, before)
    }

    func testBootstrapAcceptsExplicitEmptyListAndClearsSelection() async throws {
        let transport = FixtureTransport([.json(#"{"code":0,"data":[]}"#)])
        let api = client(transport)
        let list = try await api.bootstrap()
        let after = await api.snapshot()
        XCTAssertTrue(list.isEmpty)
        XCTAssertEqual(after.selectedVIN, "")
        XCTAssertEqual(after.selectedCarType, "")
        XCTAssertNil(after.route)
    }

    func testSentryRechecksOwnerAndSubmitsExactlyOnce() async throws {
        let owner = "{\"code\":0,\"data\":[{\"vin\":\"FIXTUREVIN0000001\",\"carType\":\"C10\",\"isOwner\":true}]}"
        let status = parked.replacingOccurrences(of: "\"soc\":70", with: "\"soc\":70,\"3636\":0")
        let transport = FixtureTransport([.json(owner), .json(status), .json(owner), .json("{\"code\":0,\"data\":{\"msgID\":\"fixture-sentry\"}}")])
        let api = client(transport)
        _ = try await api.bootstrap()
        _ = try await api.refreshStatus()
        let receipt = try await api.send(command: .sentryOn, pin: "0000")
        XCTAssertEqual(receipt.messageID, "fixture-sentry")
        let requests = await transport.allRequests()
        XCTAssertEqual(requests.filter { $0.url?.path == "/app/app-global-service/v1/vehicle/list" }.count, 2)
        let count = await transport.commandCount()
        XCTAssertEqual(count, 1)
    }

    func testSentryOwnershipRevokedDuringPreflightBlocksDispatch() async throws {
        let owner = "{\"code\":0,\"data\":[{\"vin\":\"FIXTUREVIN0000001\",\"isOwner\":true}]}"
        let shared = owner.replacingOccurrences(of: "true", with: "false")
        let status = parked.replacingOccurrences(of: "\"soc\":70", with: "\"soc\":70,\"3636\":0")
        let transport = FixtureTransport([.json(owner), .json(status), .json(shared)])
        let api = client(transport)
        _ = try await api.bootstrap()
        _ = try await api.refreshStatus()
        do { _ = try await api.send(command: .sentryOn, pin: "0000"); XCTFail("Revoked owner must not dispatch") }
        catch { XCTAssertEqual(error as? SentryControlError, .sharedAccountCannotEnable) }
        let count = await transport.commandCount()
        XCTAssertEqual(count, 0)
    }

    func testSentryPreflightRemovalInvalidatesSelectedVehicleWithoutSubmitting() async throws {
        let owner = #"{"code":0,"data":[{"vin":"FIXTUREVIN0000001","isOwner":true}]}"#
        let status = parked.replacingOccurrences(of: "\"soc\":70", with: "\"soc\":70,\"3636\":0")
        for command in [LeapCommand.sentryOn, .sentryOff] {
            let transport = FixtureTransport([.json(owner), .json(status), .json(#"{"code":0,"data":[]}"#)])
            let api = client(transport)
            _ = try await api.bootstrap()
            _ = try await api.refreshStatus()
            do { _ = try await api.send(command: command, pin: "0000"); XCTFail("Removed vehicle must not receive a command") }
            catch { XCTAssertEqual(error as? SentryControlError, .unknownOwnership) }
            let after = await api.snapshot()
            let metadata = await api.vehicleMetadataSnapshot()
            XCTAssertEqual(after.selectedVIN, "")
            XCTAssertEqual(after.selectedCarType, "")
            XCTAssertNil(after.route)
            XCTAssertTrue(metadata.isEmpty)
            do { _ = try await api.refreshStatus(); XCTFail("Removed selection must not be queried again") }
            catch { XCTAssertEqual(error as? LeapAPIError, .noVehicle) }
            do { _ = try await api.send(command: .lock, pin: "0000"); XCTFail("Removed telemetry cannot authorize another command") }
            catch { XCTAssertEqual(error as? CommandValidationError, .noVehicleStatus) }
            let count = await transport.commandCount()
            let total = await transport.count()
            XCTAssertEqual(count, 0)
            XCTAssertEqual(total, 3)
        }
    }

    func testSentryMalformedPreflightListCannotReplaceMetadataOrSubmit() async throws {
        let owner = #"{"code":0,"data":[{"vin":"FIXTUREVIN0000001","isOwner":true}]}"#
        let status = parked.replacingOccurrences(of: "\"soc\":70", with: "\"soc\":70,\"3636\":0")
        let transport = FixtureTransport([.json(owner), .json(status), .json(#"{"code":0,"data":{}}"#)])
        let api = client(transport)
        _ = try await api.bootstrap()
        _ = try await api.refreshStatus()
        let before = await api.snapshot()
        let metadataBefore = await api.vehicleMetadataSnapshot()
        do { _ = try await api.send(command: .sentryOn, pin: "0000"); XCTFail("Malformed preflight must not authorize command") }
        catch { XCTAssertEqual(error as? LeapAPIError, .invalidResponse) }
        let after = await api.snapshot()
        let metadataAfter = await api.vehicleMetadataSnapshot()
        XCTAssertEqual(after, before)
        XCTAssertEqual(metadataAfter, metadataBefore)
        let count = await transport.commandCount()
        XCTAssertEqual(count, 0)
    }

    func testGatewayCredentialRotationSurvivesLaterReadFailure() async throws {
        let reply = try gatewayReply()
        let transport = FixtureTransport([.json(reply.json), .error(.networkUnavailable)])
        let api = client(transport, session: session(expiry: instant.addingTimeInterval(30)))
        do { _ = try await api.refreshStatus(); XCTFail("The later read fails") }
        catch { XCTAssertEqual(error as? LeapAPIError, .networkUnavailable) }
        let snapshot = await api.snapshot()
        XCTAssertEqual(snapshot.newAuth?.accessToken, reply.access)
        XCTAssertEqual(snapshot.newAuth?.accountID, "fixture-account", "Keep upstream legacy account identity")
        XCTAssertEqual(snapshot.deviceID, String(repeating: "b", count: 32))
        XCTAssertEqual(snapshot.newAuth?.signKey, Data([7, 0, 1, 10]))
    }

    func testGatewayRotationIsVisibleBeforeSuspendedTelemetryCompletes() async throws {
        let reply = try gatewayReply()
        let original = session(expiry: instant.addingTimeInterval(30))
        let transport = SuspendedTransport(firstResponse: reply.json)
        let api = client(transport, session: original)
        let read = Task { try await api.refreshStatus() }
        await transport.waitUntilSuspended()
        let during = await api.snapshot()
        XCTAssertEqual(during.newAuth?.accessToken, reply.access)
        XCTAssertEqual(during.newAuth?.refreshToken, String(repeating: "n", count: 32))
        XCTAssertEqual(during.newAuth?.signKey, Data([7, 0, 1, 10]))
        XCTAssertEqual(during.deviceID, String(repeating: "b", count: 32))
        XCTAssertEqual(during.oldAuth, original.oldAuth)
        XCTAssertEqual(during.selectedVIN, original.selectedVIN)
        XCTAssertEqual(during.selectedCarType, original.selectedCarType)
        XCTAssertEqual(during.route, original.route)
        read.cancel()
        let afterCancellation = await api.snapshot()
        XCTAssertEqual(afterCancellation, during, "Cancellation must not hide already accepted credentials")
        await transport.complete(parked)
        do { _ = try await read.value; XCTFail("Cancelled telemetry must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        let afterLateResponse = await api.snapshot()
        XCTAssertEqual(afterLateResponse, during)
    }

    func testGatewayExchangeIsVisibleBeforeSuspendedTelemetryCompletes() async throws {
        let reply = try gatewayReply()
        var original = session()
        original.newAuth = nil
        let transport = SuspendedTransport(firstResponse: reply.json)
        let api = client(transport, session: original)
        let read = Task { try await api.refreshStatus() }
        await transport.waitUntilSuspended()
        let during = await api.snapshot()
        XCTAssertEqual(during.newAuth?.accessToken, reply.access)
        XCTAssertEqual(during.deviceID, String(repeating: "b", count: 32))
        XCTAssertEqual(during.selectedVIN, original.selectedVIN)
        XCTAssertEqual(during.route, original.route)
        let requests = await transport.allRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/base/base-user/account/v1/login", "/app/app-signal-service/signal/info/query"])
        await transport.complete(parked)
        _ = try await read.value
    }

    func testLegacyRotationIsVisibleWhileGatewayExchangeIsStillSuspended() async throws {
        let reply = try gatewayReply()
        let rotatedLegacy = String(repeating: "l", count: 32)
        let rotatedRefresh = String(repeating: "f", count: 32)
        let legacy: JSONValue = .object(["code": .number(0), "data": .object([
            "token": .string(rotatedLegacy), "refreshToken": .string(rotatedRefresh), "tokenExpired": .number(3600)
        ])])
        var original = session(expiry: instant.addingTimeInterval(30))
        original.phone = "13000000000"
        original.oldAuth?.refreshToken = String(repeating: "x", count: 32)
        original.newAuth?.refreshToken = ""
        let transport = SuspendedTransport(firstResponse: String(decoding: try legacy.encodedData(), as: UTF8.self))
        let api = client(transport, session: original)
        let read = Task { try await api.refreshStatus() }
        await transport.waitUntilSuspended()
        let duringExchange = await api.snapshot()
        XCTAssertEqual(duringExchange.oldAuth?.token, rotatedLegacy)
        XCTAssertEqual(duringExchange.oldAuth?.refreshToken, rotatedRefresh)
        XCTAssertEqual(duringExchange.oldAuth?.expiresAt, instant.addingTimeInterval(3600))
        XCTAssertEqual(duringExchange.newAuth, original.newAuth)
        XCTAssertEqual(duringExchange.selectedVIN, original.selectedVIN)
        XCTAssertEqual(duringExchange.route, original.route)
        await transport.complete(reply.json)
        await transport.waitUntilSuspended()
        let duringTelemetry = await api.snapshot()
        XCTAssertEqual(duringTelemetry.oldAuth?.token, rotatedLegacy)
        XCTAssertEqual(duringTelemetry.newAuth?.accessToken, reply.access)
        XCTAssertEqual(duringTelemetry.deviceID, String(repeating: "b", count: 32))
        await transport.complete(parked)
        _ = try await read.value
    }

    func testCredentialRotationDoesNotPublishPendingVehicleSelection() async throws {
        let reply = try gatewayReply()
        let vehicles = #"{"code":0,"data":[{"vin":"FIXTUREVIN0000001","carType":"C16"},{"vin":"OTHERFIXTUREVIN01","carType":"C10"}]}"#
        let clock = TestClock(instant)
        let original = session(expiry: instant.addingTimeInterval(360))
        let transport = SuspendedTransport(firstResponse: vehicles)
        let api = LeapAPI(session: original, transport: transport, crypto: FixtureCryptography(), now: { clock.read() })
        let list = try await api.bootstrap()
        clock.advance(70)
        let selection = Task { try await api.selectVehicle(list[1]) }
        await transport.waitUntilSuspended()
        await transport.complete(reply.json)
        await transport.waitUntilSuspended()
        let during = await api.snapshot()
        XCTAssertEqual(during.newAuth?.accessToken, reply.access)
        XCTAssertEqual(during.deviceID, String(repeating: "b", count: 32))
        XCTAssertEqual(during.selectedVIN, original.selectedVIN)
        XCTAssertEqual(during.selectedCarType, original.selectedCarType)
        XCTAssertEqual(during.route, original.route)
        await transport.complete(#"{"code":0,"data":{"appRegion":"https://untrusted.invalid"}}"#)
        do { try await selection.value; XCTFail("Failed route must not switch vehicles") }
        catch { XCTAssertEqual(error as? LeapAPIError, .untrustedRoute) }
        let after = await api.snapshot()
        XCTAssertEqual(after, during)
    }

    func testObservationDeadlineSnapshotIncludesRotationBeforeLateReadReturns() async throws {
        let reply = try gatewayReply()
        let original = session(expiry: instant.addingTimeInterval(30))
        let transport = SuspendedTransport(firstResponse: reply.json)
        let api = client(transport, session: original)
        let readerFinished = expectation(description: "Late read exits after cancellation")
        let observation = Task {
            try await ControlObservationDeadline(timeout: 1).run {
                defer { readerFinished.fulfill() }
                return try await api.refreshStatus()
            }
        }
        await transport.waitUntilSuspended()
        do { _ = try await observation.value; XCTFail("Suspended transport must reach deadline") }
        catch ControlObservationError.deadlineExceeded { }
        let afterDeadline = await api.snapshot()
        XCTAssertEqual(afterDeadline.newAuth?.accessToken, reply.access)
        XCTAssertEqual(afterDeadline.deviceID, String(repeating: "b", count: 32))
        XCTAssertEqual(afterDeadline.selectedVIN, original.selectedVIN)
        XCTAssertEqual(afterDeadline.route, original.route)
        await transport.complete(parked)
        await fulfillment(of: [readerFinished], timeout: 1)
        let afterLateResponse = await api.snapshot()
        XCTAssertEqual(afterLateResponse, afterDeadline)
    }

    func testLogoutAfterRotationCannotBeUndoneByLateTelemetry() async throws {
        let reply = try gatewayReply()
        let transport = SuspendedTransport(firstResponse: reply.json)
        let api = client(transport, session: session(expiry: instant.addingTimeInterval(30)))
        let read = Task { try await api.refreshStatus() }
        await transport.waitUntilSuspended()
        let during = await api.snapshot()
        XCTAssertEqual(during.newAuth?.accessToken, reply.access)
        await api.logout()
        let loggedOut = await api.snapshot()
        await transport.complete(parked)
        do { _ = try await read.value; XCTFail("Late telemetry cannot revive credentials") }
        catch { XCTAssertEqual(error as? LeapAPIError, .sessionChanged) }
        let after = await api.snapshot()
        XCTAssertEqual(after, loggedOut)
        XCTAssertNil(after.oldAuth)
        XCTAssertNil(after.newAuth)
    }

    func testLogoutRejectsDelayedCredentialRotation() async throws {
        let reply = try gatewayReply()
        let transport = SuspendedTransport()
        let api = client(transport, session: session(expiry: instant.addingTimeInterval(30)))
        let read = Task { try await api.refreshStatus() }
        await transport.waitUntilSuspended()
        await api.logout()
        let loggedOut = await api.snapshot()
        await transport.complete(reply.json)
        do { _ = try await read.value; XCTFail("A logged-out generation cannot publish rotation") }
        catch { XCTAssertEqual(error as? LeapAPIError, .sessionChanged) }
        let after = await api.snapshot()
        XCTAssertEqual(after, loggedOut)
    }

    func testCancelledImportDoesNotPublishReplacementCredentials() async throws {
        let reply = try gatewayReply()
        let transport = SuspendedTransport()
        let original = session()
        let api = client(transport, session: original)
        let imported: JSONValue = .object([
            "clientPlatform": .string("ios"), "deviceID": .string(String(repeating: "a", count: 32)),
            "accountId": .string("different-import"), "token": .string(String(repeating: "i", count: 32))
        ])
        let raw = String(decoding: try imported.encodedData(), as: UTF8.self)
        let importing = Task { try await api.importLegacyAuth(rawJSON: raw) }
        await transport.waitUntilSuspended()
        let during = await api.snapshot()
        XCTAssertEqual(during, original)
        importing.cancel()
        await transport.complete(reply.json)
        do { try await importing.value; XCTFail("Cancelled import must remain transactional") }
        catch { XCTAssertTrue(error is CancellationError) }
        let after = await api.snapshot()
        XCTAssertEqual(after, original)
    }

    func testReadOnlyAuthenticationFailureRefreshesAndRetriesOnce() async throws {
        let reply = try gatewayReply()
        let transport = FixtureTransport([.json("{}", 401), .json(reply.json), .json(parked)])
        let api = client(transport)
        _ = try await api.refreshStatus()
        let requests = await transport.allRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].url?.path, "/base/base-user/token/v1/refresh")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "token"), reply.access)
    }

    func testFailedImportDoesNotReplaceExistingSession() async throws {
        let transport = FixtureTransport([.json("{\"code\":401}")])
        let existing = session(); let api = client(transport, session: existing)
        let imported: JSONValue = .object([
            "clientPlatform": .string("android"), "deviceID": .string(String(repeating: "a", count: 32)),
            "accountId": .string("different-import"), "token": .string(String(repeating: "i", count: 32))
        ])
        do { try await api.importLegacyAuth(rawJSON: String(decoding: try imported.encodedData(), as: UTF8.self)); XCTFail("Must reject failed exchange") }
        catch { XCTAssertEqual(error as? LeapAPIError, .authenticationRequired) }
        let after = await api.snapshot(); XCTAssertEqual(after, existing)
    }

    func testSuccessfulImportExchangesBeforeBecomingAuthenticated() async throws {
        let reply = try gatewayReply()
        let transport = FixtureTransport([.json(reply.json)])
        let api = client(transport)
        let imported: JSONValue = .object([
            "clientPlatform": .string("android"), "deviceID": .string(String(repeating: "a", count: 32)),
            "accountId": .string("different-import"), "token": .string(String(repeating: "i", count: 32))
        ])
        try await api.importLegacyAuth(rawJSON: String(decoding: try imported.encodedData(), as: UTF8.self))
        let after = await api.snapshot()
        XCTAssertTrue(after.isAuthenticated); XCTAssertEqual(after.newAuth?.accountID, "different-import")
        XCTAssertEqual(after.selectedVIN, ""); XCTAssertNil(after.route)
        let requests = await transport.allRequests()
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests[0].url?.path, "/base/base-user/account/v1/login")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "token"))
    }

    func testSMSFailsClosedWithoutNetwork() async throws {
        let transport = FixtureTransport([])
        let api = client(transport)
        do { try await api.sendSMS(phone: ""); XCTFail("Must reject unintegrated SMS") }
        catch { XCTAssertEqual(error as? LeapAPIError, .nativeSMSUnavailable) }
        do { try await api.loginWithSMS(phone: "", code: ""); XCTFail("Must reject unintegrated login") }
        catch { XCTAssertEqual(error as? LeapAPIError, .nativeSMSUnavailable) }
        let count = await transport.count(); XCTAssertEqual(count, 0)
    }

    func testBootstrapListsVehiclesAndValidatesRoute() async throws {
        let transport = FixtureTransport([
            .json("{\"code\":0,\"data\":[{\"vin\":\"FIXTUREVIN0000002\",\"carType\":\"C10\"}]}"),
            .json("{\"code\":0,\"data\":{\"appRegion\":\"https://app-gw-global-master.leapmotor.com\"}}")
        ])
        let api = client(transport)
        let cars = try await api.bootstrap()
        XCTAssertEqual(cars.map(\.vin), ["FIXTUREVIN0000002"])
        let snapshot = await api.snapshot(); XCTAssertEqual(snapshot.selectedVIN, "FIXTUREVIN0000002")
        XCTAssertNotNil(snapshot.route)
    }

    func testUntrustedRouteRejectedBeforeAnyTelemetryRequest() async throws {
        let transport = FixtureTransport([.json("{\"code\":0,\"data\":{\"appRegion\":\"https://app-gw-global-master.leapmotor.com.attacker.invalid\"}}")])
        var state = session(); state.route = nil
        let api = client(transport, session: state)
        do { _ = try await api.refreshStatus(); XCTFail("Must reject route") }
        catch { XCTAssertEqual(error as? LeapAPIError, .untrustedRoute) }
        let count = await transport.count(); XCTAssertEqual(count, 1)
    }

    func testRedirectsAndChangedFinalURLAreRejected() async throws {
        for reply in [FixtureTransport.Reply.json("{}", 302), .redirected("https://attacker.invalid/")] {
            let transport = FixtureTransport([reply]); let api = client(transport)
            do { _ = try await api.refreshStatus(); XCTFail("Must reject redirect") }
            catch { XCTAssertEqual(error as? LeapAPIError, .redirectRejected) }
            let count = await transport.count(); XCTAssertEqual(count, 1)
        }
    }

    func testControlNeedsFreshParkedTelemetry() async throws {
        let transport = FixtureTransport([]); let api = client(transport)
        do { _ = try await api.send(command: .lock, pin: "0000"); XCTFail("Must reject without telemetry") }
        catch { XCTAssertEqual(error as? CommandValidationError, .noVehicleStatus) }
        let count = await transport.count(); XCTAssertEqual(count, 0)
    }

    func testControlAcceptanceNeverMeansExecution() async throws {
        let transport = FixtureTransport([.json(parked), .json("{\"code\":0,\"data\":{\"msgID\":\"fixture-job\"}}"), .json("{\"result\":7}"), .json("{\"result\":0}")])
        let api = client(transport)
        _ = try await api.refreshStatus()
        let accepted = try await api.send(command: .lock, pin: "0000")
        XCTAssertEqual(accepted.outcome, .accepted(messageID: "fixture-job"))
        let pending = try await api.pollResult(messageID: "fixture-job"); XCTAssertEqual(pending, .pending)
        let success = try await api.pollResult(messageID: "fixture-job"); XCTAssertEqual(success, .succeeded)
        let count = await transport.commandCount(); XCTAssertEqual(count, 1)
        let requests = await transport.allRequests()
        XCTAssertEqual(requests[1].url?.host, "appgateway.leapmotor.com")
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertFalse(String(decoding: requests[1].httpBody ?? Data(), as: UTF8.self).contains("oppwd=0000"))
    }

    func testControlFailuresNeverReplayPOST() async throws {
        let replies: [FixtureTransport.Reply] = [.error(.networkUnavailable), .cancelled,
            .json("{}", 500), .json("{}", 401), .json("{}", 403), .json("{\"result\":39}"),
            .json("{\"code\":401}"), .json("{}", 302), .redirected("https://attacker.invalid/"), .json("not-json")]
        for reply in replies {
            let transport = FixtureTransport([.json(parked), reply]); let api = client(transport)
            _ = try await api.refreshStatus()
            do { _ = try await api.send(command: .lock, pin: "0000"); XCTFail("Expected failure") }
            catch { XCTAssertNotNil(error as? LeapAPIError) }
            let count = await transport.commandCount(); XCTAssertEqual(count, 1)
            let total = await transport.count(); XCTAssertEqual(total, 2, "No retry or fallback destination")
        }
    }

    func testLogoutDiscardsInflightTelemetry() async throws {
        let transport = SuspendedTransport(); let api = client(transport)
        let task = Task { try await api.refreshStatus() }
        await transport.waitUntilSuspended()
        await api.logout(); await transport.complete(parked)
        do { _ = try await task.value; XCTFail("Old request must not update new session") }
        catch { XCTAssertEqual(error as? LeapAPIError, .sessionChanged) }
        let snapshot = await api.snapshot(); XCTAssertFalse(snapshot.isAuthenticated); XCTAssertEqual(snapshot.selectedVIN, "")
    }

    func testLogoutDuringRefreshPreventsControlDispatch() async throws {
        let clock = TestClock(instant)
        let transport = SuspendedTransport(firstResponse: parked)
        let api = LeapAPI(session: session(expiry: instant.addingTimeInterval(360)), transport: transport,
                          crypto: FixtureCryptography(), now: { clock.read() })
        _ = try await api.refreshStatus()
        clock.advance(70)
        let command = Task { try await api.send(command: .lock, pin: "0000") }
        await transport.waitUntilSuspended()
        await api.logout(); await transport.complete("{\"code\":0}")
        do { _ = try await command.value; XCTFail("Logout must invalidate preflight") }
        catch { XCTAssertEqual(error as? LeapAPIError, .sessionChanged) }
        let count = await transport.commandCount(); XCTAssertEqual(count, 0)
    }

    func testConcurrentOperationsFailClosed() async throws {
        let transport = SuspendedTransport(); let api = client(transport)
        let task = Task { try await api.refreshStatus() }
        await transport.waitUntilSuspended()
        do { _ = try await api.refreshStatus(); XCTFail("Should serialize") }
        catch { XCTAssertEqual(error as? LeapAPIError, .busy) }
        await transport.complete(parked); _ = try await task.value
    }
}
