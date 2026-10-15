import XCTest
@testable import LeapCore

final class JSONIdentifierTests: XCTestCase {
    // Insert numeric tokens directly: constructing a Double fixture first would
    // lose the very digits these decoding regressions are intended to cover.
    private func importJSON(accountID: String) -> String {
        """
        {"clientPlatform":"android","deviceID":"\(String(repeating: "d", count: 32))",
         "data":{"appLoginVO":{"accountId":\(accountID),"token":"\(String(repeating: "x", count: 32))"}}}
        """
    }

    private func submissionJSON(identifier: String) -> [String] {
        ["msgID", "msgId", "eventId"].map {
            "{\"code\":0,\"data\":{\"\($0)\":\(identifier)}}"
        } + ["{\"result\":0,\"data\":\(identifier)}"]
    }

    func testDecodedNumericScalarsRejectUnsafeIntegerRange() throws {
        for token in ["9007199254740992", "9007199254740993", "9007199254740994",
                      "-9007199254740992", "-9007199254740993", "9223372036854775807", "1e20"] {
            let value = try JSONValue(data: Data(token.utf8))
            XCTAssertNil(value.scalarString, "An unsafe numeric identifier must not become a rounded string: \(token)")
            XCTAssertNotNil(value.doubleValue, "Numeric telemetry must still be available as a Double")
        }
    }

    func testSafeNumericScalarsRetainExistingConversions() throws {
        for token in ["0", "24", "9007199254740991", "-9007199254740991", "24.5"] {
            XCTAssertEqual(try JSONValue(data: Data(token.utf8)).scalarString, token)
        }
        XCTAssertNil(JSONValue.number(.infinity).scalarString)
        XCTAssertNil(JSONValue.number(.nan).scalarString)
    }

    func testLegacyImportRejectsUnsafeNumericAccountID() {
        for token in ["9007199254740992", "9007199254740993", "-9007199254740993"] {
            XCTAssertThrowsError(try SessionImporter.parseLegacyJSON(importJSON(accountID: token)), token) {
                XCTAssertEqual($0 as? SessionImportError, .missingCredentials)
            }
        }
    }

    func testLegacyImportAcceptsSafeNumericAccountID() throws {
        for token in ["24", "9007199254740991"] {
            let session = try SessionImporter.parseLegacyJSON(importJSON(accountID: token))
            XCTAssertEqual(session.oldAuth?.accountID, token)
        }
    }

    func testLegacyImportPreservesLargeStringAccountID() throws {
        for identifier in ["9007199254740993", "9223372036854775807", "009007199254740993"] {
            let session = try SessionImporter.parseLegacyJSON(importJSON(accountID: "\"\(identifier)\""))
            XCTAssertEqual(session.oldAuth?.accountID, identifier)
        }
    }

    func testControlSubmissionDropsUnsafeNumericPollingIDs() throws {
        for token in ["9007199254740992", "9007199254740993", "-9007199254740993"] {
            for response in submissionJSON(identifier: token) {
                let submission = try ControlSubmission(response: JSONValue(data: Data(response.utf8)))
                XCTAssertNil(submission.messageID, response)
                XCTAssertEqual(submission.outcome, .accepted(messageID: nil))
            }
        }
    }

    func testControlSubmissionPreservesSafeNumericPollingIDs() throws {
        for token in ["24", "9007199254740991"] {
            for response in submissionJSON(identifier: token) {
                let submission = try ControlSubmission(response: JSONValue(data: Data(response.utf8)))
                XCTAssertEqual(submission.messageID, token)
            }
        }
    }

    func testControlSubmissionPreservesLargeStringPollingIDs() throws {
        for identifier in ["9007199254740993", "9223372036854775807", "009007199254740993"] {
            for response in submissionJSON(identifier: "\"\(identifier)\"") {
                let submission = try ControlSubmission(response: JSONValue(data: Data(response.utf8)))
                XCTAssertEqual(submission.messageID, identifier)
            }
        }
    }
}
