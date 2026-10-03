import CryptoKit
import Foundation
import XCTest
@testable import PaperGIFMac

final class UpdateServiceTests: XCTestCase {
    func testVersionComparisonIsNumericAndPadsMissingComponents() {
        XCTAssertTrue(SoftwareVersion.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(SoftwareVersion.isNewer("v1.0.1", than: "1.0"))
        XCTAssertTrue(SoftwareVersion.isNewer("1.0.0", than: "0.0.0"))
        XCTAssertFalse(SoftwareVersion.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(SoftwareVersion.isNewer("1.0.0", than: "1.0.1"))
        XCTAssertFalse(SoftwareVersion.isNewer("2.0.0", than: "2.0.0"))
    }

    func testParsesReleaseAndKeepsOnlyGitHubHTTPSDownloads() throws {
        let json = #"""
        {
          "tag_name": "v1.2.0",
          "html_url": "https://github.com/Levi-5k/PaperRemote/releases/tag/v1.2.0",
          "body": "Notes",
          "assets": [
            {"name": "papergif-release.json", "browser_download_url": "https://github.com/Levi-5k/PaperRemote/releases/download/v1.2.0/papergif-release.json"},
            {"name": "evil.zip", "browser_download_url": "http://github.com/evil.zip"},
            {"name": "other.zip", "browser_download_url": "https://example.com/other.zip"}
          ]
        }
        """#
        let (tag, notes, _, downloads) = try ReleaseClient.parseRelease(Data(json.utf8))

        XCTAssertEqual(tag, "v1.2.0")
        XCTAssertEqual(notes, "Notes")
        XCTAssertEqual(Set(downloads.keys), ["papergif-release.json"])
    }

    func testManifestRejectsMalformedChecksumsAndPathNames() throws {
        let checksum = String(repeating: "a", count: 64)
        let valid = #"{"version":"1.2.0","firmware":{"name":"fw.bin","sha256":"\#(checksum)","size":10}}"#
        XCTAssertEqual(try ReleaseClient.decodeManifest(Data(valid.utf8)).firmware?.size, 10)

        let shortHash = #"{"version":"1.2.0","mac":{"name":"a.zip","sha256":"abc","size":10}}"#
        XCTAssertThrowsError(try ReleaseClient.decodeManifest(Data(shortHash.utf8)))
        let traversal = #"{"version":"1.2.0","mac":{"name":"../a.zip","sha256":"\#(checksum)","size":10}}"#
        XCTAssertThrowsError(try ReleaseClient.decodeManifest(Data(traversal.utf8)))
    }

    func testFileChecksumMatchesCryptoKit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data((0..<3_000_000).map { UInt8($0 & 0xFF) })
        try data.write(to: url)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(try ReleaseClient.sha256Hex(of: url), expected)
    }

    func testFirmwareMultipartBodyWrapsImageInOneFilePart() {
        let firmware = Data([0xE9, 0x00, 0xFF])
        let body = FirmwareInstaller.multipartBody(firmware: firmware, boundary: "B")
        let prefix = Data("--B\r\nContent-Disposition: form-data; name=\"firmware\"; filename=\"firmware.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)

        XCTAssertEqual(body, prefix + firmware + Data("\r\n--B--\r\n".utf8))
    }

    func testUnsignedCurrentAppCannotVerifyUpdates() {
        let unsigned = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: unsigned, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unsigned) }

        XCTAssertThrowsError(try UpdateService.verifySignature(of: unsigned, matches: unsigned))
    }
}
