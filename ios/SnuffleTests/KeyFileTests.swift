import CryptoKit
import SnuffleKit
import XCTest
@testable import Snuffle

/// Key files picked or opened from Files and AirDrop.
final class KeyFileTests: XCTestCase {
    private func write(_ text: String, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadsTheKeyAndTheKeyIdFromApplesFileName() throws {
        let pem = P256.Signing.PrivateKey().pemRepresentation
        let file = try XCTUnwrap(KeyFile(url: write(pem, name: "AuthKey_ABC123DEFG.p8")))
        XCTAssertEqual(file.keyId, "ABC123DEFG")
        XCTAssertEqual(file.pem, pem)
        // An individual key needs nothing else.
        XCTAssertTrue(try AppStoreConnectToken(issuerId: "", keyId: file.keyId ?? "", privateKeyPEM: file.pem).isIndividual)
    }

    func testARenamedKeyStillReadsWithoutAKeyId() throws {
        let file = try XCTUnwrap(KeyFile(url: write(P256.Signing.PrivateKey().pemRepresentation, name: "my-key.p8")))
        XCTAssertNil(file.keyId)
    }

    func testRejectsFilesThatAreNotKeys() throws {
        XCTAssertNil(KeyFile(url: try write("hello", name: "AuthKey_ABC123DEFG.p8")))
    }
}
