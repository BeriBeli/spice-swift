import Foundation
import SwiftSpice

enum SessionBenchmarkError: String, Error, CustomStringConvertible {
    case usage = "invalid_arguments (see --help)"
    case invalidConnectionFile = "invalid_connection_file"
    case unsupportedProxy = "connection_file_requires_unsupported_proxy"
    case connectionFailed = "connection_failed"
    case sessionEnded = "session_ended"
    case timedOut = "operation_timed_out"
    case markerNotReady = "initial_marker_not_found (fullscreen and reset the guest page)"
    case invalidSample = "invalid_interaction_sample (see JSONL)"
    case noFrames = "no_desktop_frames"
    case outputFailed = "output_failed"

    var description: String { rawValue }
}

struct BenchmarkConfiguration: Sendable {
    var endpoint: SpiceEndpoint
    // Configuration is never serialized or included in error descriptions.
    var password: String
    var observeSeconds: Int = 15
    var headless = false
    var markerBase: UInt64?
    var samples = 50
    var warmup = 5
    var intervalMilliseconds = 100
    var timeoutSeconds = 10
    var readyTimeoutSeconds = 60
    var traceURL: URL?
    var label = "unlabelled"

    static let help = """
        usage: spice-session-benchmark HOST PORT [options]
               spice-session-benchmark CONNECTION.vv [options]

        Observe: --observe-seconds N [--headless]
        Interact: --marker-base HEX16 --trace FILE [--samples N] [--warmup N]
                  [--interval-ms N] [--ready-timeout-seconds N]
        Common: --timeout-seconds N --label NAME --enable-h264|--enable-h265
                --tls|--tls-insecure-for-testing-only (HOST PORT only)

        JSON report goes to stdout; progress and fixed error categories go to stderr.
        SPICE_PASSWORD overrides the .vv ticket. Direct TCP/TLS .vv files are
        supported, including ca and host-subject. Proxy routing is unsupported.
        Interaction requires Benchmarks/Session/guest-marker.html in the guest,
        fullscreen at 100% zoom, with the same base token and counter reset to zero.
        Keep the local benchmark window visible. No host keyboard capture is used.
        """

    static func parse(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        var positional: [String] = []
        var flags: Set<String> = []
        var options: [String: String] = [:]
        let switches: Set<String> = [
            "--headless", "--tls", "--tls-insecure-for-testing-only",
            "--enable-h264", "--enable-h265",
        ]
        let values: Set<String> = [
            "--observe-seconds", "--marker-base", "--trace", "--samples", "--warmup",
            "--interval-ms", "--timeout-seconds", "--ready-timeout-seconds", "--label",
        ]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if switches.contains(argument) {
                guard flags.insert(argument).inserted else { throw SessionBenchmarkError.usage }
            } else if values.contains(argument) {
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--"),
                    options.updateValue(arguments[index], forKey: argument) == nil
                else {
                    throw SessionBenchmarkError.usage
                }
            } else {
                guard !argument.hasPrefix("--") else { throw SessionBenchmarkError.usage }
                positional.append(argument)
            }
            index += 1
        }
        guard !flags.isSuperset(of: ["--enable-h264", "--enable-h265"]),
            !flags.isSuperset(of: ["--tls", "--tls-insecure-for-testing-only"])
        else {
            throw SessionBenchmarkError.usage
        }
        let codec: SpiceVideoCodecPolicy =
            flags.contains("--enable-h264")
            ? .h264AndMJPEG : flags.contains("--enable-h265") ? .h265AndMJPEG : .mjpegOnly
        var configuration: Self
        if positional.count == 1 {
            guard !flags.contains("--tls"),
                !flags.contains("--tls-insecure-for-testing-only")
            else {
                throw SessionBenchmarkError.usage
            }
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: positional[0]))
            } catch { throw SessionBenchmarkError.invalidConnectionFile }
            defer { try? handle.close() }
            do {
                let data = try handle.read(upToCount: 1_048_577) ?? Data()
                guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
                    throw SessionBenchmarkError.invalidConnectionFile
                }
                configuration = try fromVirtViewer(text)
            } catch let error as SessionBenchmarkError { throw error } catch {
                throw SessionBenchmarkError.invalidConnectionFile
            }
            configuration.endpoint.videoCodecPolicy = codec
        } else {
            guard positional.count == 2, !positional[0].isEmpty,
                let port = UInt16(positional[1]), port > 0
            else {
                throw SessionBenchmarkError.usage
            }
            let tls: TLSTrustPolicy? =
                flags.contains("--tls")
                ? .system
                : flags.contains("--tls-insecure-for-testing-only") ? .insecureForTestingOnly : nil
            configuration = Self(
                endpoint: SpiceEndpoint(
                    host: positional[0], port: port, tlsPolicy: tls, videoCodecPolicy: codec),
                password: ""
            )
        }
        configuration.password = environment["SPICE_PASSWORD"] ?? configuration.password
        func integer(_ name: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let text = options[name] else { return fallback }
            guard let value = Int(text), range.contains(value) else {
                throw SessionBenchmarkError.usage
            }
            return value
        }
        configuration.observeSeconds = try integer(
            "--observe-seconds", default: 15, range: 1...3_600)
        configuration.samples = try integer("--samples", default: 50, range: 1...1_000)
        configuration.warmup = try integer("--warmup", default: 5, range: 0...100)
        configuration.intervalMilliseconds = try integer(
            "--interval-ms", default: 100, range: 0...60_000)
        configuration.timeoutSeconds = try integer("--timeout-seconds", default: 10, range: 1...300)
        configuration.readyTimeoutSeconds = try integer(
            "--ready-timeout-seconds", default: 60, range: 1...3_600)
        configuration.headless = flags.contains("--headless")
        if let label = options["--label"] {
            guard !label.isEmpty, label.utf8.count <= 128,
                !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else {
                throw SessionBenchmarkError.usage
            }
            configuration.label = label
        }
        if let token = options["--marker-base"] {
            guard token.utf8.count == 16, let base = UInt64(token, radix: 16),
                !base.addingReportingOverflow(UInt64(configuration.samples + configuration.warmup))
                    .overflow,
                let trace = options["--trace"], !trace.isEmpty,
                options["--observe-seconds"] == nil, !configuration.headless
            else {
                throw SessionBenchmarkError.usage
            }
            configuration.markerBase = base
            configuration.traceURL = URL(fileURLWithPath: trace)
        } else if ["--trace", "--samples", "--warmup", "--interval-ms", "--ready-timeout-seconds"]
            .contains(where: { options[$0] != nil })
        {
            throw SessionBenchmarkError.usage
        }
        return configuration
    }

    static func fromVirtViewer(_ text: String) throws -> Self {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        var active = false
        var fields: [String: String] = [:]
        for line in normalized.split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                active = line.lowercased() == "[virt-viewer]"
                continue
            }
            guard active else { continue }
            guard let equals = line.firstIndex(of: "=") else {
                throw SessionBenchmarkError.invalidConnectionFile
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty,
                !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                fields.updateValue(value, forKey: key) == nil
            else {
                throw SessionBenchmarkError.invalidConnectionFile
            }
        }
        guard fields["type"]?.lowercased() == "spice",
            let host = fields["host"], !host.isEmpty
        else {
            throw SessionBenchmarkError.invalidConnectionFile
        }
        guard (fields["proxy"] ?? "").isEmpty,
            !host.lowercased().hasPrefix("pvespiceproxy:")
        else {
            throw SessionBenchmarkError.unsupportedProxy
        }
        func port(_ key: String) throws -> UInt16? {
            guard let text = fields[key], text != "-1" else { return nil }
            guard let port = UInt16(text), port > 0 else {
                throw SessionBenchmarkError.invalidConnectionFile
            }
            return port
        }
        let tlsPort = try port("tls-port")
        let plainPort = try port("port")
        guard let port = tlsPort ?? plainPort else {
            throw SessionBenchmarkError.invalidConnectionFile
        }
        let ca = fields["ca"].flatMap { $0.isEmpty ? nil : $0 }
        let subject = fields["host-subject"].flatMap { $0.isEmpty ? nil : $0 }
        let ciphers = fields["tls-ciphers"] ?? ""
        // Prefer TLS for every channel; never fall back to TCP after a TLS error.
        guard ca == nil || tlsPort != nil,
            subject == nil || (tlsPort != nil && ca != nil),
            (fields["secure-channels"] ?? "").isEmpty || tlsPort != nil,
            ciphers.isEmpty || ciphers == "DEFAULT",
            (fields["host-key"] ?? "").isEmpty
        else {
            throw SessionBenchmarkError.invalidConnectionFile
        }
        let tls: TLSTrustPolicy?
        if let ca, let subject {
            tls = .virtViewerCertificateAuthority(
                certificates: [Data(ca.utf8)], expectedSubject: subject)
        } else if let ca {
            tls = .customCertificateAuthority(certificates: [Data(ca.utf8)])
        } else {
            tls = tlsPort == nil ? nil : .system
        }
        return Self(
            endpoint: SpiceEndpoint(host: host, port: port, tlsPolicy: tls),
            password: fields["password"] ?? "")
    }
}

enum SessionMarker {
    static func token(_ value: UInt64) -> String { String(format: "%016llx", value) }
    static func checksum(_ value: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: value) ^ UInt32(truncatingIfNeeded: value >> 32) ^ 0x5350_4943
    }
}
