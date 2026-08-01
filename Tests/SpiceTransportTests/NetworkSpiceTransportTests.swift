import Foundation
import Network
import Security
import SpiceTransport
import SpiceTransportNetwork
import Testing

@Suite("NetworkSpiceTransport")
struct NetworkSpiceTransportTests {
    @Test func cancellationStopsPendingEstablishment() async throws {
        let transport = NetworkSpiceTransport(host: "192.0.2.1", port: 5900)
        let task = Task {
            try await transport.connect()
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            try await task.value
            Issue.record("cancelled connection unexpectedly succeeded")
        } catch TransportError.cancelled {
            // Expected: cancellation must not wait for the TCP timeout.
        } catch {
            Issue.record("expected cancellation, got \(error)")
        }
    }

    @Test func closeStopsPendingEstablishmentAndAllowsRetry() async throws {
        let transport = NetworkSpiceTransport(host: "192.0.2.1", port: 5900)

        for _ in 0 ..< 25 {
            let task = Task {
                try await transport.connect()
            }
            try await Task.sleep(for: .milliseconds(5))
            await transport.close()

            do {
                try await task.value
                Issue.record("closed connection unexpectedly succeeded")
            } catch TransportError.cancelled {
                // Expected: close invalidates this generation and wakes connect().
            } catch {
                Issue.record("expected cancellation after close, got \(error)")
            }
        }
    }

    @Test func exchangesBytesWithLocalTCPListener() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "swiftspice.network-test")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) {
                data,
                _,
                _,
                error in
                guard error == nil, let data else {
                    return
                }
                connection.send(content: data, completion: .idempotent)
            }
        }

        let states = AsyncStream<NWListener.State> { continuation in
            listener.stateUpdateHandler = { state in
                continuation.yield(state)
                switch state {
                case .failed, .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }

        var port: NWEndpoint.Port?
        for await state in states {
            switch state {
            case .ready:
                port = listener.port
            case let .failed(error):
                Issue.record("local listener failed: \(error)")
            default:
                break
            }
            if port != nil {
                break
            }
        }
        let resolvedPort = try #require(port)

        let transport = NetworkSpiceTransport(
            host: "127.0.0.1",
            port: resolvedPort.rawValue
        )
        try await transport.connect()
        try await transport.write(Data([1, 2, 3, 4]))
        #expect(try await transport.read(minimum: 1, maximum: 1_024) == Data([1, 2, 3, 4]))
        await transport.close()
    }

    @Test func timesOutWhenPeerNeverCompletesTLSHandshake() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "swiftspice.tls-timeout-test")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
        }

        let states = AsyncStream<NWListener.State> { continuation in
            listener.stateUpdateHandler = { state in
                continuation.yield(state)
                switch state {
                case .failed, .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }

        var port: NWEndpoint.Port?
        for await state in states {
            if case .ready = state {
                port = listener.port
                break
            }
        }
        let resolvedPort = try #require(port)
        let transport = NetworkSpiceTransport(
            host: "127.0.0.1",
            port: resolvedPort.rawValue,
            tlsPolicy: .system,
            establishmentTimeout: .milliseconds(100)
        )

        await #expect(throws: TransportError.timeout) {
            try await transport.connect()
        }
    }

    @Test func terminalTLSWaitingTrustErrorsDoNotBecomeTimeouts() {
        let invalidChain = NWError.tls(errSSLXCertChainInvalid)
        #expect(NetworkSpiceTransport.terminalTLSWaitingFailure(invalidChain) == .tlsFailure(
            String(describing: invalidChain)
        ))

        let badCertificate = NWError.tls(errSSLBadCert)
        #expect(NetworkSpiceTransport.terminalTLSWaitingFailure(badCertificate) == .tlsFailure(
            String(describing: badCertificate)
        ))

        #expect(NetworkSpiceTransport.terminalTLSWaitingFailure(
            .posix(.ENETDOWN)
        ) == nil)
        #expect(NetworkSpiceTransport.terminalTLSWaitingFailure(
            .tls(errSSLWouldBlock)
        ) == nil)
    }

    @Test func trustsEscapedVirtViewerCAAndChecksOverriddenServerName() throws {
        let serverCertificate = try #require(certificate(fromPEM: Self.serverCertificatePEM))
        let escapedCA = Data(Self.caCertificatePEM.replacingOccurrences(of: "\n", with: "\\n").utf8)

        let matchingTrust = try makeTrust(
            certificate: serverCertificate,
            serverName: "connection-address.example.test"
        )
        #expect(NetworkSpiceTransport.evaluateCustomCertificateAuthority(
            trust: matchingTrust,
            certificates: [escapedCA],
            serverName: "ravada.example.test"
        ))

        let mismatchingTrust = try makeTrust(
            certificate: serverCertificate,
            serverName: "connection-address.example.test"
        )
        #expect(!NetworkSpiceTransport.evaluateCustomCertificateAuthority(
            trust: mismatchingTrust,
            certificates: [escapedCA],
            serverName: "wrong.example.test"
        ))
    }

    @Test func rejectsMalformedCustomCA() throws {
        let serverCertificate = try #require(certificate(fromPEM: Self.serverCertificatePEM))
        let trust = try makeTrust(certificate: serverCertificate, serverName: "ravada.example.test")
        #expect(!NetworkSpiceTransport.evaluateCustomCertificateAuthority(
            trust: trust,
            certificates: [Data("not a certificate".utf8)],
            serverName: "ravada.example.test"
        ))
    }

    @Test func acceptsLegacyVirtViewerSubjectWithoutSANOrServerAuthEKU() throws {
        let serverCertificate = try #require(certificate(fromPEM: Self.legacyServerCertificatePEM))
        let escapedCA = Data(
            Self.legacyCACertificatePEM.replacingOccurrences(of: "\n", with: "\\n").utf8
        )
        let trust = try makeTrust(
            certificate: serverCertificate,
            serverName: "connection-address.example.test"
        )

        #expect(NetworkSpiceTransport.evaluateVirtViewerCertificateAuthority(
            trust: trust,
            certificates: [escapedCA],
            expectedSubject: "C=SG,L=Singapore,O=SwiftSpice,CN=ravada.example.test"
        ))

        let modernHostnameTrust = try makeTrust(
            certificate: serverCertificate,
            serverName: "connection-address.example.test"
        )
        #expect(!NetworkSpiceTransport.evaluateCustomCertificateAuthority(
            trust: modernHostnameTrust,
            certificates: [escapedCA],
            serverName: "ravada.example.test"
        ))

        let canonicalSubjectTrust = try makeTrust(
            certificate: serverCertificate,
            serverName: "connection-address.example.test"
        )
        #expect(NetworkSpiceTransport.evaluateVirtViewerCertificateAuthority(
            trust: canonicalSubjectTrust,
            certificates: [escapedCA],
            expectedSubject: " c=sg, l=Singapore, o=swiftspice, cn=RAVADA.EXAMPLE.TEST"
        ))
    }

    @Test func rejectsLegacySubjectMismatchWrongCAAndMalformedSubject() throws {
        let serverCertificate = try #require(certificate(fromPEM: Self.legacyServerCertificatePEM))
        let legacyCA = Data(Self.legacyCACertificatePEM.utf8)
        let expectedSubject = "C=SG,L=Singapore,O=SwiftSpice,CN=ravada.example.test"

        let mismatchingSubjectTrust = try makeTrust(
            certificate: serverCertificate,
            serverName: "connection-address.example.test"
        )
        #expect(!NetworkSpiceTransport.evaluateVirtViewerCertificateAuthority(
            trust: mismatchingSubjectTrust,
            certificates: [legacyCA],
            expectedSubject: "C=SG,L=Singapore,O=SwiftSpice,CN=wrong.example.test"
        ))

        let incompleteSubjectTrust = try makeTrust(
            certificate: serverCertificate,
            serverName: "connection-address.example.test"
        )
        #expect(!NetworkSpiceTransport.evaluateVirtViewerCertificateAuthority(
            trust: incompleteSubjectTrust,
            certificates: [legacyCA],
            expectedSubject: "CN=ravada.example.test"
        ))

        let reorderedSubjectTrust = try makeTrust(
            certificate: serverCertificate,
            serverName: "connection-address.example.test"
        )
        #expect(!NetworkSpiceTransport.evaluateVirtViewerCertificateAuthority(
            trust: reorderedSubjectTrust,
            certificates: [legacyCA],
            expectedSubject: "CN=ravada.example.test,O=SwiftSpice,L=Singapore,C=SG"
        ))

        let wrongCATrust = try makeTrust(
            certificate: serverCertificate,
            serverName: "connection-address.example.test"
        )
        #expect(!NetworkSpiceTransport.evaluateVirtViewerCertificateAuthority(
            trust: wrongCATrust,
            certificates: [Data(Self.caCertificatePEM.utf8)],
            expectedSubject: expectedSubject
        ))

        let malformedCATrust = try makeTrust(
            certificate: serverCertificate,
            serverName: "connection-address.example.test"
        )
        #expect(!NetworkSpiceTransport.evaluateVirtViewerCertificateAuthority(
            trust: malformedCATrust,
            certificates: [Data("not a certificate".utf8)],
            expectedSubject: expectedSubject
        ))

        let malformedSubjectTrust = try makeTrust(
            certificate: serverCertificate,
            serverName: "connection-address.example.test"
        )
        #expect(!NetworkSpiceTransport.evaluateVirtViewerCertificateAuthority(
            trust: malformedSubjectTrust,
            certificates: [legacyCA],
            expectedSubject: "C=SG,CN"
        ))

        let invalidEscapeTrust = try makeTrust(
            certificate: serverCertificate,
            serverName: "connection-address.example.test"
        )
        #expect(!NetworkSpiceTransport.evaluateVirtViewerCertificateAuthority(
            trust: invalidEscapeTrust,
            certificates: [legacyCA],
            expectedSubject: "C=SG,O=Swift\\qSpice,CN=ravada.example.test"
        ))
    }

    @Test func legacyPolicyStillEnforcesCertificateValidityDates() throws {
        let serverCertificate = try #require(certificate(fromPEM: Self.legacyServerCertificatePEM))
        let legacyCA = Data(Self.legacyCACertificatePEM.utf8)
        let expectedSubject = "C=SG,L=Singapore,O=SwiftSpice,CN=ravada.example.test"

        let notYetValidTrust = try makeTrust(
            certificate: serverCertificate,
            serverName: "connection-address.example.test",
            verifyDate: Date(timeIntervalSince1970: 1_735_689_600)
        )
        #expect(!NetworkSpiceTransport.evaluateVirtViewerCertificateAuthority(
            trust: notYetValidTrust,
            certificates: [legacyCA],
            expectedSubject: expectedSubject
        ))

        let expiredTrust = try makeTrust(
            certificate: serverCertificate,
            serverName: "connection-address.example.test",
            verifyDate: Date(timeIntervalSince1970: 2_208_988_800)
        )
        #expect(!NetworkSpiceTransport.evaluateVirtViewerCertificateAuthority(
            trust: expiredTrust,
            certificates: [legacyCA],
            expectedSubject: expectedSubject
        ))
    }

    private func makeTrust(
        certificate: SecCertificate,
        serverName: String,
        verifyDate: Date = Date(timeIntervalSince1970: 1_785_628_800)
    ) throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            certificate,
            SecPolicyCreateSSL(true, serverName as CFString),
            &trust
        )
        #expect(status == errSecSuccess)
        let resolvedTrust = try #require(trust)
        #expect(SecTrustSetVerifyDate(resolvedTrust, verifyDate as CFDate) == errSecSuccess)
        return resolvedTrust
    }

    private func certificate(fromPEM pem: String) -> SecCertificate? {
        let body = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
        guard let der = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    private static let legacyCACertificatePEM = """
    -----BEGIN CERTIFICATE-----
    MIIDKTCCAhGgAwIBAgIUECii2NyCWabqQjScJS+yaUReyvwwDQYJKoZIhvcNAQEL
    BQAwJDEiMCAGA1UEAwwZU3dpZnRTcGljZS1MZWdhY3ktVGVzdC1DQTAeFw0yNjA4
    MDEwOTMyMjFaFw0zNjA3MjkwOTMyMjFaMCQxIjAgBgNVBAMMGVN3aWZ0U3BpY2Ut
    TGVnYWN5LVRlc3QtQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCZ
    wz7uNPysx+G/HU2IbskHWregABLSzi//3PaplIZCCKmvN2/FVk5XiX6v6d6xsDGf
    OpCumYdXt2eO5zu6Cn9vHvlz9PSsZqZMyIYu68VQdExEiodNA7+3sIx0NiCYl0T2
    t5ALKzAH+YuCS9O7uyx5jeCVIxs1m3yrYyNk+KQUJJGSkSvR4sAVWJtE+ivjgbmu
    Xa29q9PKgR0say8Hjg5OXCg7Q7bkEpoi6GFgb+UCeY9/T0iY6yDq9LHTyonvQ0Or
    ZQ7FHMDYNP7aOGj4oTpguNPDWj4g8vSmUS6ebgcAApcMhAsWGp+ayRM/7VT4y6sF
    GMtgUdQlmm7MvKJMl+5xAgMBAAGjUzBRMB0GA1UdDgQWBBTnRZzbG3m1YyGnfd82
    hS+e7fKT8jAfBgNVHSMEGDAWgBTnRZzbG3m1YyGnfd82hS+e7fKT8jAPBgNVHRMB
    Af8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQBpVizLTIM8lmPppWZH33PyYmD/
    AMrosRpmQFNguEyjoCEEGHxS0gX4zMcn9s1xoD4EdOGH3V/10lTIcWR+2iCjhWUu
    O4mw3DUvBW9sixVEr9ktcW2SgfF+rJ+mdZVK0ew+pEIl8Cn8lgDrOy/hrvFxnzVn
    iiaGzWRub5DLz28jEpjn02Sv2xxgG7Rl4CI7lor++UbEHj2UJ7p0R9cCV8zsx7dE
    bdDhgdGIf81AdhLONaIjgUltyOznSFzRYYBGwCzBVn/aY9ceofSOhm2P3SnrPHSG
    ThoQXvbj+Ka6fK8fDnTCFnvcDbF386Ix2hJzAq7Jg7qPR1XHKQE/McGWyNYD
    -----END CERTIFICATE-----
    """

    private static let legacyServerCertificatePEM = """
    -----BEGIN CERTIFICATE-----
    MIIDNTCCAh2gAwIBAgIBAjANBgkqhkiG9w0BAQsFADAkMSIwIAYDVQQDDBlTd2lm
    dFNwaWNlLUxlZ2FjeS1UZXN0LUNBMB4XDTI2MDgwMTA5MzI1MVoXDTM2MDcyOTA5
    MzI1MVowVDELMAkGA1UEBhMCU0cxEjAQBgNVBAcMCVNpbmdhcG9yZTETMBEGA1UE
    CgwKU3dpZnRTcGljZTEcMBoGA1UEAwwTcmF2YWRhLmV4YW1wbGUudGVzdDCCASIw
    DQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAJIoDabSy1xeIvtAw8yyTxHN3ZC6
    9aZ0Y64IuzPzmFs5Q0FWK8i2kHVgOpgVd26A+lIuWvjgUyrCSW8ZVfbPjIGbFRnx
    n9BTrzSMeQAR2WtgT8UVkKFrwgmDIGrWlYGKDYQ1iyH80XOIJLoW+LT9GqBSqIFw
    QocG/F2JuD59ri0RY0cUfcHGdfmmRY7wA2et/awSfq3sBOxDTUL+tOh9QUM7K2ZQ
    7oiElLrDAVglvbY4gqZPW09fk5a7QANPQSyt9wcFytQzduNZ8Pgs9Sm3bLGiDVla
    hRZGvwlqe572lva8XLwnV7wgE5z7jTRBK6k8NUpoqnpkOgTAJKAGCVK8+bcCAwEA
    AaNCMEAwHQYDVR0OBBYEFEdjOWcBt+ZeFHDU/52SuBhZJvSdMB8GA1UdIwQYMBaA
    FOdFnNsbebVjIad93zaFL57t8pPyMA0GCSqGSIb3DQEBCwUAA4IBAQAsF7wWY4vW
    6qb0hFODtkSnrxFihYD16Ht5Jk0rtN3X4d3ROQNNilnylGTyG/PH6s+VltncjNdR
    H+Il86t09xUmGx3ug+pQKU0C6FaqLsjJsqEmhpKhXv2pxCW7X71udBxHlw0BhJcy
    WwfwLxD9N11POoft2/P0eqtiOtS4hiF6xJqkXX5uUrP51kCWlHLMFx7wxTxq2uT6
    8S4pam/HEQVDsqeKdmmCmPRoGQyVblkV3uoMoG3SlqKm4TXpdcPexE+BsU2pxo/v
    OAWcSy6yO0TgWrQJc3yVU/224z+M5XMS8p5XBx3VP5g1SjcD00tW4HEmJbk0FiNz
    dUqdP8xwzq8g
    -----END CERTIFICATE-----
    """

    private static let caCertificatePEM = """
    -----BEGIN CERTIFICATE-----
    MIIDKzCCAhOgAwIBAgIULOjO6wujMKbgl3VaLXc2bI7zVt0wDQYJKoZIhvcNAQEL
    BQAwHTEbMBkGA1UEAwwSU3dpZnRTcGljZS1UZXN0LUNBMB4XDTI2MDgwMTA3MjUx
    NVoXDTM2MDcyOTA3MjUxNVowHTEbMBkGA1UEAwwSU3dpZnRTcGljZS1UZXN0LUNB
    MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAklf9Pa9K05f7l2XrxY9D
    9A/mo6d7edI4qfosiZ1iTQcV7x8ylFjo0rsfq3cIqN8Kw316ginxK5wAVtUJbM9y
    yiHgr1ZGHyzWkBtIVGDJPycy14iiWur465ZmtCiJfHY2wmGICkrV1fD/TxElgRIh
    L3Ssn9xipXnMhggZoerl1HDX+Lp+uXZPnZ7achq7kLXU9Kl53Hyy3Z5qw1Y+6jUO
    qpr1LlD0Qx429hXrIXD00SjZZ80pDnSfsV8KlQjRoFwVzGoTI/F7OVomUyfatiMB
    tjBXxr64j0T66aBlPQ/nKHxpaNKioCSxRsElPTiVn8Mt9s1jsDdWprgM5VwN8+5g
    wQIDAQABo2MwYTAdBgNVHQ4EFgQUVZ/qXyM0ZCJSuANGpovN5eBBhsAwHwYDVR0j
    BBgwFoAUVZ/qXyM0ZCJSuANGpovN5eBBhsAwDwYDVR0TAQH/BAUwAwEB/zAOBgNV
    HQ8BAf8EBAMCAQYwDQYJKoZIhvcNAQELBQADggEBAHS5S5fA+FqjPjac9KZ9+NGM
    oCdQ4C0VUYApAkC4ZOYoNuE3waZEAf/9e58lpi0i7Xg9nlSaU/+PGzp1ZbcOQ0fc
    fOZTh7SvkzptIUsY89/e5QsoLar1A6INBqVQNZjmJ/WCStE41wVJr4dBEWArn94N
    +bkI/zefslPr6GJIfYZkXHvawGHfxpPB/b1ox6Lmv/7P8AJgkUnWBJfjjzt2+h5c
    xNE18YWELz3h8DmQp9FJwo2cEKwoEiDwQfwO4IlangOk10jTM0FtmcKA7NkXRhNs
    tYdAerAjPrm0XidLZnLzGtjYMyQ96Zx7U7YbUlY+/jyN1ym0aDvNg5fN8qh8XWQ=
    -----END CERTIFICATE-----
    """

    private static let serverCertificatePEM = """
    -----BEGIN CERTIFICATE-----
    MIIDYDCCAkigAwIBAgIUVFdmfm5GjDdgsjg9lUpaOlcK1kQwDQYJKoZIhvcNAQEL
    BQAwHTEbMBkGA1UEAwwSU3dpZnRTcGljZS1UZXN0LUNBMB4XDTI2MDgwMTA3MjUx
    NVoXDTI3MDgwMTA3MjUxNVowHjEcMBoGA1UEAwwTcmF2YWRhLmV4YW1wbGUudGVz
    dDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAJdEgN5JeNcX7md5/Bdr
    tw4tMs4vYKlx6wUaUBpPqgKvHpD5PpWeQqAnF2lG5/9PcS1drHfm6hmSYADlY1eL
    9ZUBalfCWiERzqQS/1JdpbZRrXHdikaRXdKhv5+upyGQX6YicdQ0YOSwh31YDHAt
    ZVfNkabDAtZfGKKy4CZmgL1hM8IBowBOrodbKuuos2uYRA3fLlKKG3P7alUBmmm3
    aL07hjkNmXxc/oMj8qtcaDwuvRUFi0pqAJgjcZsWxEGQCtxldIoTJSy5UpOWQwyU
    qVzBeYpWbOZr74LsUlbWB/4bjaESBiWArTqWRCbPyqcfl6F5wBWsODSStkHVBwOC
    0XUCAwEAAaOBljCBkzAeBgNVHREEFzAVghNyYXZhZGEuZXhhbXBsZS50ZXN0MAwG
    A1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgWgMBMGA1UdJQQMMAoGCCsGAQUFBwMB
    MB0GA1UdDgQWBBTXsbZ1odsswslbaNSvsv6SMO14rDAfBgNVHSMEGDAWgBRVn+pf
    IzRkIlK4A0ami83l4EGGwDANBgkqhkiG9w0BAQsFAAOCAQEAG7iIsg7mxg1bzBVW
    M1LWaoZEZT+f2r10NaG57IO4FohbE6l/GlbO8uBFCm6cVoGE+srh7wVLai+Q5Ldh
    LI/7BNgPvQtPuA+xTjwoQtjjEOsJaHEw/giw5sOZiE6TbSSszqtcAH+J0A8/+ZbS
    E62+e9v+y3jCYCKcm9dWKtWxcopKzhYGbSElRidIPacljCNtE4gj9a3/WH9z/9sJ
    b+N9doMBBpTNra5nh12wwUxs5eTXp8x9lcnYCf4Me6y9uBoviC0xG3/UNZWOl2Ws
    ysOA20CIyjV9ZfIN69fN3y2hMPrtEARha+f9VEmu3NZMcBJ3a1donA9m4+deQBuc
    gxgzKw==
    -----END CERTIFICATE-----
    """
}
