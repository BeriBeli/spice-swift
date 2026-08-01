import Foundation
import Security

// Implements the subject_to_x509_name + X509_NAME_cmp compatibility shape
// used by spice-common without adding an OpenSSL runtime dependency.
enum VirtViewerCertificateSubject {
    private struct Attribute: Equatable {
        let oid: [UInt64]
        let value: [UInt8]
    }

    private static let maximumSubjectBytes = 16 * 1_024
    private static let maximumRDNCount = 128
    private static let maximumAttributeValueBytes = 8 * 1_024
    private static let maximumOIDArcs = 32

    static func matches(_ expectedSubject: String, certificate: SecCertificate) -> Bool {
        guard
            let expected = parseExpectedSubject(expectedSubject),
            let encodedSubject = SecCertificateCopyNormalizedSubjectSequence(certificate) as Data?,
            encodedSubject.count <= maximumSubjectBytes,
            let actual = parseEncodedSubject(encodedSubject)
        else {
            return false
        }
        return actual == expected
    }

    private static func parseExpectedSubject(_ subject: String) -> [[Attribute]]? {
        guard !subject.isEmpty, subject.utf8.count <= maximumSubjectBytes else {
            return nil
        }

        enum State {
            case key
            case value
        }

        var state = State.key
        var key = ""
        var value = ""
        var isEscaped = false
        var result: [[Attribute]] = []

        func makeAttribute(key: String, value: String) -> Attribute? {
            guard
                !key.isEmpty,
                !value.isEmpty,
                value.utf8.count <= maximumAttributeValueBytes,
                let oid = oid(for: key),
                let canonicalValue = canonicalize(value),
                !canonicalValue.isEmpty
            else {
                return nil
            }
            return Attribute(oid: oid, value: canonicalValue)
        }

        for character in subject {
            if isEscaped {
                guard character == "\\" || character == "," else {
                    return nil
                }
                switch state {
                case .key:
                    key.append(character)
                case .value:
                    value.append(character)
                }
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            switch state {
            case .key:
                if character == " " && key.isEmpty {
                    continue
                }
                if character == "=" {
                    guard !key.isEmpty else {
                        return nil
                    }
                    state = .value
                } else if character == "," {
                    return nil
                } else {
                    key.append(character)
                }
            case .value:
                if character == "," {
                    guard
                        let attribute = makeAttribute(key: key, value: value),
                        result.count < maximumRDNCount
                    else {
                        return nil
                    }
                    result.append([attribute])
                    key = ""
                    value = ""
                    state = .key
                } else {
                    value.append(character)
                }
            }
        }

        guard !isEscaped else {
            return nil
        }
        switch state {
        case .key:
            return key.isEmpty && !result.isEmpty ? result : nil
        case .value:
            guard
                let attribute = makeAttribute(key: key, value: value),
                result.count < maximumRDNCount
            else {
                return nil
            }
            result.append([attribute])
            return result
        }
    }

    private static func parseEncodedSubject(_ data: Data) -> [[Attribute]]? {
        var outerReader = DERReader(data)
        guard
            let name = outerReader.read(expectedTag: 0x30),
            outerReader.isAtEnd
        else {
            return nil
        }

        var nameReader = DERReader(name)
        var result: [[Attribute]] = []
        while !nameReader.isAtEnd {
            guard
                result.count < maximumRDNCount,
                let encodedRDN = nameReader.read(expectedTag: 0x31)
            else {
                return nil
            }
            var rdnReader = DERReader(encodedRDN)
            var attributes: [Attribute] = []
            while !rdnReader.isAtEnd {
                guard
                    let encodedAttribute = rdnReader.read(expectedTag: 0x30)
                else {
                    return nil
                }
                var attributeReader = DERReader(encodedAttribute)
                guard
                    let encodedOID = attributeReader.read(expectedTag: 0x06),
                    let oid = decodeOID(encodedOID),
                    let encodedValue = attributeReader.readAny(),
                    attributeReader.isAtEnd,
                    encodedValue.content.count <= maximumAttributeValueBytes,
                    let value = decodeString(
                        tag: encodedValue.tag,
                        content: encodedValue.content
                    ),
                    let canonicalValue = canonicalize(value),
                    !canonicalValue.isEmpty
                else {
                    return nil
                }
                attributes.append(Attribute(oid: oid, value: canonicalValue))
            }

            // The virt-viewer grammar creates one AttributeValueAssertion per
            // RDN. Reject a certificate with a multi-valued RDN rather than
            // flattening it into a subject string with weaker semantics.
            guard attributes.count == 1 else {
                return nil
            }
            result.append(attributes)
        }
        return result.isEmpty ? nil : result
    }

    private static func oid(for key: String) -> [UInt64]? {
        let aliases: [String: [UInt64]] = [
            "c": [2, 5, 4, 6],
            "countryname": [2, 5, 4, 6],
            "st": [2, 5, 4, 8],
            "stateorprovincename": [2, 5, 4, 8],
            "l": [2, 5, 4, 7],
            "localityname": [2, 5, 4, 7],
            "street": [2, 5, 4, 9],
            "streetaddress": [2, 5, 4, 9],
            "o": [2, 5, 4, 10],
            "organizationname": [2, 5, 4, 10],
            "ou": [2, 5, 4, 11],
            "organizationalunitname": [2, 5, 4, 11],
            "cn": [2, 5, 4, 3],
            "commonname": [2, 5, 4, 3],
            "serialnumber": [2, 5, 4, 5],
            "title": [2, 5, 4, 12],
            "description": [2, 5, 4, 13],
            "postalcode": [2, 5, 4, 17],
            "givenname": [2, 5, 4, 42],
            "sn": [2, 5, 4, 4],
            "surname": [2, 5, 4, 4],
            "initials": [2, 5, 4, 43],
            "generationqualifier": [2, 5, 4, 44],
            "dnqualifier": [2, 5, 4, 46],
            "pseudonym": [2, 5, 4, 65],
            "dc": [0, 9, 2_342, 19_200_300, 100, 1, 25],
            "domaincomponent": [0, 9, 2_342, 19_200_300, 100, 1, 25],
            "uid": [0, 9, 2_342, 19_200_300, 100, 1, 1],
            "userid": [0, 9, 2_342, 19_200_300, 100, 1, 1],
            "emailaddress": [1, 2, 840, 1, 113_549, 1, 9, 1],
        ]
        if let alias = aliases[key.lowercased()] {
            return alias
        }

        let components = key.split(separator: ".", omittingEmptySubsequences: false)
        guard
            components.count >= 2,
            components.count <= maximumOIDArcs,
            components.allSatisfy({ !$0.isEmpty }),
            let first = UInt64(components[0]),
            let second = UInt64(components[1]),
            first <= 2,
            first == 2 || second <= 39
        else {
            return nil
        }
        var arcs = [first, second]
        for component in components.dropFirst(2) {
            guard let arc = UInt64(component) else {
                return nil
            }
            arcs.append(arc)
        }
        return arcs
    }

    private static func decodeOID(_ data: Data) -> [UInt64]? {
        guard !data.isEmpty else {
            return nil
        }
        var subidentifiers: [UInt64] = []
        var value: UInt64 = 0
        var isContinuation = false
        for byte in data {
            guard value <= (UInt64.max >> 7) else {
                return nil
            }
            value = (value << 7) | UInt64(byte & 0x7f)
            isContinuation = byte & 0x80 != 0
            if !isContinuation {
                subidentifiers.append(value)
                value = 0
            }
        }
        guard
            !isContinuation,
            !subidentifiers.isEmpty,
            subidentifiers.count + 1 <= maximumOIDArcs
        else {
            return nil
        }

        let firstCombined = subidentifiers.removeFirst()
        let first: UInt64
        let second: UInt64
        if firstCombined < 40 {
            first = 0
            second = firstCombined
        } else if firstCombined < 80 {
            first = 1
            second = firstCombined - 40
        } else {
            first = 2
            second = firstCombined - 80
        }
        return [first, second] + subidentifiers
    }

    private static func decodeString(tag: UInt8, content: Data) -> String? {
        switch tag {
        case 0x0c:
            String(data: content, encoding: .utf8)
        case 0x12, 0x13, 0x16, 0x1a:
            String(data: content, encoding: .ascii)
        case 0x14:
            String(data: content, encoding: .isoLatin1)
        case 0x1c:
            String(data: content, encoding: .utf32BigEndian)
        case 0x1e:
            String(data: content, encoding: .utf16BigEndian)
        default:
            nil
        }
    }

    private static func canonicalize(_ value: String) -> [UInt8]? {
        let bytes = Array(value.utf8)
        guard bytes.count <= maximumAttributeValueBytes else {
            return nil
        }
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var pendingSpace = false
        for byte in bytes {
            if byte == 0x20 {
                if !result.isEmpty {
                    pendingSpace = true
                }
                continue
            }
            if pendingSpace {
                result.append(0x20)
                pendingSpace = false
            }
            result.append((0x41 ... 0x5a).contains(byte) ? byte + 0x20 : byte)
        }
        return result
    }
}

private struct DERReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    var isAtEnd: Bool {
        offset == bytes.count
    }

    mutating func read(expectedTag: UInt8) -> Data? {
        guard let value = readAny(), value.tag == expectedTag else {
            return nil
        }
        return value.content
    }

    mutating func readAny() -> (tag: UInt8, content: Data)? {
        guard offset < bytes.count else {
            return nil
        }
        let tag = bytes[offset]
        offset += 1
        guard tag & 0x1f != 0x1f, offset < bytes.count else {
            return nil
        }

        let firstLengthByte = bytes[offset]
        offset += 1
        let length: Int
        if firstLengthByte & 0x80 == 0 {
            length = Int(firstLengthByte)
        } else {
            let count = Int(firstLengthByte & 0x7f)
            guard
                count > 0,
                count <= MemoryLayout<Int>.size,
                offset + count <= bytes.count,
                bytes[offset] != 0
            else {
                return nil
            }
            var decodedLength = 0
            for byte in bytes[offset ..< offset + count] {
                guard decodedLength <= (Int.max >> 8) else {
                    return nil
                }
                decodedLength = (decodedLength << 8) | Int(byte)
            }
            guard decodedLength >= 128 else {
                return nil
            }
            offset += count
            length = decodedLength
        }

        guard length <= bytes.count - offset else {
            return nil
        }
        let content = Data(bytes[offset ..< offset + length])
        offset += length
        return (tag, content)
    }
}
