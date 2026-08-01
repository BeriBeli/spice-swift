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

    private func makeTrust(certificate: SecCertificate, serverName: String) throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            certificate,
            SecPolicyCreateSSL(true, serverName as CFString),
            &trust
        )
        #expect(status == errSecSuccess)
        return try #require(trust)
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
