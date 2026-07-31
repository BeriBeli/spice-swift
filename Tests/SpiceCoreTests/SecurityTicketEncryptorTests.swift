import Foundation
import Security
import Testing
@testable import SpiceCore
@testable import SpiceCryptoSecurity

@Suite("SPICE ticket encryption")
struct SecurityTicketEncryptorTests {
    @Test func rejectsPasswordLongerThanProtocolLimit() {
        let encryptor = SecurityTicketEncryptor()
        #expect(throws: AuthenticationError.passwordTooLong(maximumBytes: 60)) {
            try encryptor.encryptTicket(
                password: Data(repeating: 1, count: 61),
                publicKeyDER: Data()
            )
        }
    }

    @Test func rejectsEmbeddedNULBeforeParsingKey() {
        let encryptor = SecurityTicketEncryptor()
        #expect(throws: AuthenticationError.passwordContainsNUL) {
            try encryptor.encryptTicket(
                password: Data([1, 0, 2]),
                publicKeyDER: Data()
            )
        }
    }

    @Test func encryptsSPKIPublicKeyWithOAEPAndTrailingNUL() throws {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 1_024,
        ]
        var creationError: Unmanaged<CFError>?
        let privateKey = try #require(SecKeyCreateRandomKey(
            attributes as CFDictionary,
            &creationError
        ))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        var exportError: Unmanaged<CFError>?
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(publicKey, &exportError)) as Data
        let spki = makeSubjectPublicKeyInfo(pkcs1: pkcs1)
        #expect(spki.count == 162)

        let password = Data("secret".utf8)
        let encrypted = try SecurityTicketEncryptor().encryptTicket(
            password: password,
            publicKeyDER: spki
        )
        #expect(encrypted.count == 128)

        var decryptionError: Unmanaged<CFError>?
        let decrypted = try #require(SecKeyCreateDecryptedData(
            privateKey,
            .rsaEncryptionOAEPSHA1,
            encrypted as CFData,
            &decryptionError
        )) as Data
        #expect(decrypted == Data("secret\0".utf8))
    }

    private func makeSubjectPublicKeyInfo(pkcs1: Data) -> Data {
        let rsaAlgorithmIdentifier = Data([
            0x30, 0x0d,
            0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
            0x05, 0x00,
        ])
        var bitStringValue = Data([0])
        bitStringValue.append(pkcs1)

        var body = rsaAlgorithmIdentifier
        body.append(0x03)
        body.append(contentsOf: encodeDERLength(bitStringValue.count))
        body.append(bitStringValue)

        var result = Data([0x30])
        result.append(contentsOf: encodeDERLength(body.count))
        result.append(body)
        return result
    }

    private func encodeDERLength(_ length: Int) -> [UInt8] {
        if length < 0x80 {
            return [UInt8(length)]
        }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
}
