import Foundation
import Testing
@testable import SwiftSpice

@Suite("Native WebDAV server")
struct SpiceWebDAVServerTests {
    @Test func readOnlyServerReadsExplicitRootAndRejectsMutationAndEscape() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello".utf8).write(to: root.appendingPathComponent("hello.txt"))
        let server = try SpiceWebDAVServer(root: root)

        let get = try #require(await server.receive(
            clientID: 1,
            data: request("GET", "/hello.txt")
        ).first)
        #expect(status(get) == 200)
        #expect(get.suffix(5) == Data("hello".utf8))

        let propfind = try #require(await server.receive(
            clientID: 1,
            data: request("PROPFIND", "/", headers: ["Depth": "1"])
        ).first)
        #expect(status(propfind) == 207)
        let propfindText = String(decoding: propfind, as: UTF8.self)
        #expect(propfindText.contains("<D:href>/</D:href>"))
        #expect(propfindText.contains("<D:href>/hello.txt</D:href>"))
        #expect(!propfindText.contains("<D:href>//</D:href>"))
        #expect(!propfindText.contains(root.lastPathComponent))
        #expect(propfindText.contains("<D:getetag>"))
        #expect(propfindText.contains("<D:getlastmodified>"))

        let put = try #require(await server.receive(
            clientID: 1,
            data: request("PUT", "/new.txt", body: Data("no".utf8))
        ).first)
        #expect(status(put) == 403)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("new.txt").path
        ))

        let traversal = try #require(await server.receive(
            clientID: 1,
            data: request("GET", "/../outside.txt")
        ).first)
        #expect(status(traversal) == 403)
    }

    @Test func readWriteServerSupportsBoundedFileLifecycle() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try SpiceWebDAVServer(root: root, accessMode: .readWrite)

        #expect(status(try #require(await server.receive(
            clientID: 2,
            data: request("MKCOL", "/folder")
        ).first)) == 201)
        #expect(status(try #require(await server.receive(
            clientID: 2,
            data: request("PUT", "/folder/a.txt", body: Data("abc".utf8))
        ).first)) == 201)
        #expect(status(try #require(await server.receive(
            clientID: 2,
            data: request(
                "COPY",
                "/folder/a.txt",
                headers: ["Destination": "/folder/b.txt"]
            )
        ).first)) == 201)
        #expect(status(try #require(await server.receive(
            clientID: 2,
            data: request(
                "MOVE",
                "/folder/b.txt",
                headers: ["Destination": "/folder/c.txt"]
            )
        ).first)) == 201)
        #expect(status(try #require(await server.receive(
            clientID: 2,
            data: request("DELETE", "/folder/c.txt")
        ).first)) == 204)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("folder/a.txt").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("folder/c.txt").path
        ))
    }

    @Test func parserHandlesFragmentationPipeliningAndLimits() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try SpiceWebDAVServer(
            root: root,
            maximumClients: 1,
            maximumHeaderBytes: 128,
            maximumBodyBytes: 3
        )
        let first = request("OPTIONS", "/")
        #expect(try await server.receive(clientID: 7, data: first.prefix(8)).isEmpty)
        var remainder = Data(first.dropFirst(8))
        remainder.append(request("OPTIONS", "/"))
        #expect(try await server.receive(clientID: 7, data: remainder).count == 2)

        await #expect(throws: SpiceWebDAVServerError.tooManyClients) {
            try await server.receive(clientID: 8, data: Data("G".utf8))
        }
        await server.close(clientID: 7)
        await #expect(throws: SpiceWebDAVServerError.bodyTooLarge) {
            try await server.receive(
                clientID: 8,
                data: request("PUT", "/large", body: Data(repeating: 1, count: 4))
            )
        }
    }

    @Test func existingSymlinkCannotEscapeAuthorizedRoot() async throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        let server = try SpiceWebDAVServer(root: root, accessMode: .readWrite)

        let get = try #require(await server.receive(
            clientID: 1,
            data: request("GET", "/escape/secret.txt")
        ).first)
        #expect(status(get) == 403)
        let put = try #require(await server.receive(
            clientID: 1,
            data: request("PUT", "/escape/new.txt", body: Data("x".utf8))
        ).first)
        #expect(status(put) == 403)
        #expect(!FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("new.txt").path
        ))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spice-webdav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func request(
        _ method: String,
        _ path: String,
        headers: [String: String] = [:],
        body: Data = Data()
    ) -> Data {
        var fields = headers
        if !body.isEmpty { fields["Content-Length"] = String(body.count) }
        var text = "\(method) \(path) HTTP/1.1\r\nHost: fixture.invalid\r\n"
        for key in fields.keys.sorted() {
            text += "\(key): \(fields[key]!)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    private func status(_ response: Data) -> Int? {
        let firstLine = String(decoding: response, as: UTF8.self)
            .components(separatedBy: "\r\n").first
        return firstLine?.split(separator: " ").dropFirst().first.flatMap {
            Int(String($0))
        }
    }
}
