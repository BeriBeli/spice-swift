import Foundation
import Security
import SpiceCore

package struct SecurityTicketEncryptor: TicketEncrypting {
    package init() {}

    package func encryptTicket(
        password: consuming Data,
        publicKeyDER: Data
    ) throws(AuthenticationError) -> Data {
        guard password.count <= 60 else {
            throw .passwordTooLong(maximumBytes: 60)
        }
        guard !password.contains(0) else {
            throw .passwordContainsNUL
        }

        let keyData = try extractPKCS1PublicKey(from: publicKeyDER)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 1_024,
        ]
        var creationError: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            keyData as CFData,
            attributes as CFDictionary,
            &creationError
        ) else {
            let description = creationError?.takeRetainedValue().localizedDescription
            throw .encryptionFailed(description ?? "SecKeyCreateWithData failed")
        }
        let algorithm = SecKeyAlgorithm.rsaEncryptionOAEPSHA1
        guard SecKeyIsAlgorithmSupported(key, .encrypt, algorithm) else {
            throw .unsupportedPublicKey
        }

        var plaintext = password
        plaintext.append(0)
        defer {
            plaintext.resetBytes(in: plaintext.indices)
        }

        var encryptionError: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            key,
            algorithm,
            plaintext as CFData,
            &encryptionError
        ) else {
            let description = encryptionError?.takeRetainedValue().localizedDescription
            throw .encryptionFailed(description ?? "SecKeyCreateEncryptedData failed")
        }
        let result = encrypted as Data
        guard result.count == 128 else {
            throw .encryptionFailed("unexpected RSA ciphertext size \(result.count)")
        }
        return result
    }

    private func extractPKCS1PublicKey(
        from subjectPublicKeyInfo: Data
    ) throws(AuthenticationError) -> Data {
        do {
            var outerReader = DERReader(subjectPublicKeyInfo)
            let outerSequence = try outerReader.readValue(tag: 0x30)
            try outerReader.requireFullyConsumed()

            var sequenceReader = DERReader(outerSequence)
            if sequenceReader.peekTag() == 0x02 {
                return subjectPublicKeyInfo
            }
            _ = try sequenceReader.readValue(tag: 0x30)
            let bitString = try sequenceReader.readValue(tag: 0x03)
            try sequenceReader.requireFullyConsumed()
            guard bitString.first == 0 else {
                throw AuthenticationError.invalidPublicKey
            }
            return bitString.dropFirst()
        } catch let error as AuthenticationError {
            throw error
        } catch {
            throw .invalidPublicKey
        }
    }
}

private struct DERReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    func peekTag() -> UInt8? {
        guard offset < data.count else {
            return nil
        }
        return data[data.startIndex + offset]
    }

    mutating func readValue(tag expectedTag: UInt8) throws(AuthenticationError) -> Data {
        guard offset < data.count else {
            throw .invalidPublicKey
        }
        let tag = data[data.startIndex + offset]
        offset += 1
        guard tag == expectedTag else {
            throw .invalidPublicKey
        }
        let length = try readLength()
        let (end, overflow) = offset.addingReportingOverflow(length)
        guard !overflow, end <= data.count else {
            throw .invalidPublicKey
        }
        let value = data.subdata(in: offset..<end)
        offset = end
        return value
    }

    func requireFullyConsumed() throws(AuthenticationError) {
        guard offset == data.count else {
            throw .invalidPublicKey
        }
    }

    private mutating func readLength() throws(AuthenticationError) -> Int {
        guard offset < data.count else {
            throw .invalidPublicKey
        }
        let first = data[data.startIndex + offset]
        offset += 1
        if first & 0x80 == 0 {
            return Int(first)
        }

        let byteCount = Int(first & 0x7f)
        guard byteCount > 0, byteCount <= MemoryLayout<Int>.size,
              data.count - offset >= byteCount
        else {
            throw .invalidPublicKey
        }
        var length = 0
        for _ in 0..<byteCount {
            let (shifted, shiftOverflow) = length.multipliedReportingOverflow(by: 256)
            let byte = Int(data[data.startIndex + offset])
            let (next, addOverflow) = shifted.addingReportingOverflow(byte)
            guard !shiftOverflow, !addOverflow else {
                throw .invalidPublicKey
            }
            length = next
            offset += 1
        }
        return length
    }
}
