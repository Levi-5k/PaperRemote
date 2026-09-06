import Foundation
import XCTest
@testable import PaperGIFMac

final class HTTPRequestParserTests: XCTestCase {
    func testCompleteAndPartialRequests() {
        let request = Data("POST /action HTTP/1.1\r\nContent-Length: 4\r\n\r\ntest".utf8)
        XCTAssertEqual(HTTPRequestParser.parse(request), .complete(request))
        XCTAssertEqual(HTTPRequestParser.parse(request.dropLast()), .incomplete)
    }

    func testRejectsInvalidContentLengthsWithoutTrapping() {
        for value in ["", "-1", "+1", "1.0", String(Int.max)] {
            let request = Data("POST / HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n".utf8)
            XCTAssertEqual(HTTPRequestParser.parse(request), .invalid, value)
        }
    }

    func testRejectsConflictingContentLengthsAndTransferEncoding() {
        let conflicting = Data("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx".utf8)
        XCTAssertEqual(HTTPRequestParser.parse(conflicting), .invalid)

        let encoded = Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        XCTAssertEqual(HTTPRequestParser.parse(encoded), .invalid)
    }

    func testRejectsOversizedRequestAndMalformedHeader() {
        XCTAssertEqual(
            HTTPRequestParser.parse(Data(repeating: 65, count: HTTPRequestParser.maximumRequestBytes)),
            .invalid
        )
        let malformed = Data([0x47, 0x45, 0x54, 0x20, 0xFF, 0x0D, 0x0A, 0x0D, 0x0A])
        XCTAssertEqual(HTTPRequestParser.parse(malformed), .invalid)
    }

    func testAuthorizationFieldAndSchemeAreCaseInsensitiveButTokenIsExact() {
        let matching = Data("GET /status HTTP/1.1\r\nauthorization: bearer SecretToken\r\n\r\n".utf8)
        XCTAssertTrue(HTTPRequestParser.hasBearerToken("SecretToken", in: matching))
        XCTAssertFalse(HTTPRequestParser.hasBearerToken("secrettoken", in: matching))
    }
}
