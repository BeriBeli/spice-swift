import Foundation
import Synchronization
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

    @Test func blockedClientDoesNotPreventAnIndependentClientFromCompleting() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("slow".utf8).write(to: root.appendingPathComponent("slow.txt"))
        try Data("fast".utf8).write(to: root.appendingPathComponent("fast.txt"))

        let gate = WebDAVFileOperationGate(blocking: [.init(clientID: 41, sequence: 1)])
        let executor = SpiceFilesystemTaskExecutor()
        let server = try SpiceWebDAVServer(
            root: root,
            filesystemExecutor: executor,
            fileOperationWillBegin: gate.operationWillBegin
        )
        let slowDelivery = WebDAVDeliveryProbe()
        #expect(try await server.submit(
            clientID: 41,
            data: request("GET", "/slow.txt")
        ) { result in
            slowDelivery.accept(result)
        })
        try #require(await gate.waitUntilStarted(clientID: 41, sequence: 1))

        let fastDelivery = WebDAVDeliveryProbe()
        #expect(try await server.submit(
            clientID: 42,
            data: request("GET", "/fast.txt")
        ) { result in
            fastDelivery.accept(result)
        })
        let completedBeforeRelease = await fastDelivery.waitUntilDelivered(count: 1)
        gate.release(clientID: 41, sequence: 1)
        #expect(completedBeforeRelease)

        let fastResponse = try #require(fastDelivery.outcomes.first?.responses?.first)
        #expect(status(fastResponse) == 200)
        #expect(fastResponse.suffix(4) == Data("fast".utf8))
        try #require(await slowDelivery.waitUntilDelivered(count: 1))
        let slowResponse = try #require(slowDelivery.outcomes.first?.responses?.first)
        #expect(status(slowResponse) == 200)
        #expect(slowResponse.suffix(4) == Data("slow".utf8))
        #expect(gate.startedOperations == [
            .init(clientID: 41, sequence: 1),
            .init(clientID: 42, sequence: 1),
        ])
        let diagnostics = await server.diagnosticsSnapshot()
        #expect(diagnostics.pendingJobs == 0)
        #expect(diagnostics.currentRetainedBytes == 0)
        #expect(diagnostics.executor.peakActiveJobs == 2)
    }

    @Test func pipelinedRequestsForOneClientExecuteAndRespondInOrder() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("first".utf8).write(to: root.appendingPathComponent("first.txt"))
        try Data("second".utf8).write(to: root.appendingPathComponent("second.txt"))

        let firstKey = WebDAVOperationKey(clientID: 51, sequence: 1)
        let gate = WebDAVFileOperationGate(blocking: [firstKey])
        let server = try SpiceWebDAVServer(
            root: root,
            filesystemExecutor: SpiceFilesystemTaskExecutor(),
            fileOperationWillBegin: gate.operationWillBegin
        )
        var pipeline = request("GET", "/first.txt")
        pipeline.append(request("GET", "/second.txt"))
        let delivery = WebDAVDeliveryProbe()
        #expect(try await server.submit(clientID: 51, data: pipeline) { result in
            delivery.accept(result)
        })
        try #require(await gate.waitUntilStarted(clientID: 51, sequence: 1))
        #expect(!(await gate.waitUntilStarted(
            clientID: 51,
            sequence: 2,
            timeout: .milliseconds(100)
        )))

        gate.release(clientID: 51, sequence: 1)
        try #require(await gate.waitUntilStarted(clientID: 51, sequence: 2))
        try #require(await delivery.waitUntilDelivered(count: 2))
        let ordered = delivery.outcomes.compactMap(\.responses).flatMap { $0 }
        #expect(ordered.count == 2)
        #expect(ordered.first?.suffix(5) == Data("first".utf8))
        #expect(ordered.last?.suffix(6) == Data("second".utf8))
        #expect(gate.startedOperations == [
            firstKey,
            .init(clientID: 51, sequence: 2),
        ])
    }

    @Test func nextClientOperationWaitsUntilThePreviousResponseSenderReturns() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("first".utf8).write(to: root.appendingPathComponent("first.txt"))
        try Data("second".utf8).write(to: root.appendingPathComponent("second.txt"))

        let gate = WebDAVFileOperationGate(blocking: [])
        let sender = WebDAVResponseSenderGate()
        let server = try SpiceWebDAVServer(
            root: root,
            filesystemExecutor: SpiceFilesystemTaskExecutor(),
            fileOperationWillBegin: gate.operationWillBegin
        )
        #expect(try await server.submit(
            clientID: 52,
            data: request("GET", "/first.txt")
        ) { result in
            await sender.accept(result)
        })
        #expect(try await server.submit(
            clientID: 52,
            data: request("GET", "/second.txt")
        ) { result in
            await sender.accept(result)
        })

        await sender.waitUntilAccepted(count: 1)
        #expect(gate.startedOperations == [.init(clientID: 52, sequence: 1)])
        #expect(!(await gate.waitUntilStarted(
            clientID: 52,
            sequence: 2,
            timeout: .milliseconds(100)
        )))
        let blocked = await server.diagnosticsSnapshot()
        #expect(blocked.pendingJobs == 2)
        #expect(blocked.reservedResponseBytes > 0)
        #expect(blocked.currentRetainedBytes >= blocked.reservedResponseBytes)

        await sender.releaseFirst()
        try #require(await gate.waitUntilStarted(clientID: 52, sequence: 2))
        await sender.waitUntilAccepted(count: 2)
        let outcomes = await sender.outcomes
        #expect(outcomes.count == 2)
        #expect(outcomes[0].responses?.first?.suffix(5) == Data("first".utf8))
        #expect(outcomes[1].responses?.first?.suffix(6) == Data("second".utf8))
        await waitForWebDAVServer(server) {
            $0.pendingJobs == 0
                && $0.reservedResponseBytes == 0
                && $0.currentRetainedBytes == 0
        }
    }

    @Test func serverAdmissionLimitsRejectAtomicallyAtExactBoundaries() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let options = request("OPTIONS", "/")
        let headerLimit = 128
        let inputRetainedBytes = options.count + 128 + 512
        let exactRetainedLimit = inputRetainedBytes + headerLimit

        let pendingGate = WebDAVFileOperationGate(
            blocking: [.init(clientID: 81, sequence: 1)]
        )
        let pendingServer = try SpiceWebDAVServer(
            root: root,
            maximumHeaderBytes: headerLimit,
            maximumBodyBytes: 0,
            maximumPendingJobs: 1,
            maximumQueuedRetainedBytes: exactRetainedLimit * 2,
            filesystemExecutor: SpiceFilesystemTaskExecutor(),
            fileOperationWillBegin: pendingGate.operationWillBegin
        )
        let pendingDelivery = WebDAVDeliveryProbe()
        #expect(try await pendingServer.submit(clientID: 81, data: options) { result in
            pendingDelivery.accept(result)
        })
        try #require(await pendingGate.waitUntilStarted(clientID: 81, sequence: 1))
        let pendingBefore = await pendingServer.diagnosticsSnapshot()
        await #expect(throws: SpiceWebDAVPipelineError.tooManyPendingJobs(
            actual: 2,
            maximum: 1
        )) {
            try await pendingServer.submit(clientID: 82, data: options) { _ in true }
        }
        let pendingAfter = await pendingServer.diagnosticsSnapshot()
        #expect(pendingAfter.clients == pendingBefore.clients)
        #expect(pendingAfter.pendingJobs == pendingBefore.pendingJobs)
        #expect(pendingAfter.pendingRetainedBytes == pendingBefore.pendingRetainedBytes)
        #expect(pendingAfter.reservedResponseBytes == pendingBefore.reservedResponseBytes)
        #expect(pendingAfter.currentRetainedBytes == pendingBefore.currentRetainedBytes)
        #expect(pendingAfter.rejectedJobs == pendingBefore.rejectedJobs + 1)
        pendingGate.release(clientID: 81, sequence: 1)
        try #require(await pendingDelivery.waitUntilDelivered(count: 1))
        #expect(pendingDelivery.outcomes.first?.responses?.count == 1)

        let byteGate = WebDAVFileOperationGate(
            blocking: [.init(clientID: 91, sequence: 1)]
        )
        let byteServer = try SpiceWebDAVServer(
            root: root,
            maximumHeaderBytes: headerLimit,
            maximumBodyBytes: 0,
            maximumPendingJobs: 2,
            maximumQueuedRetainedBytes: exactRetainedLimit,
            filesystemExecutor: SpiceFilesystemTaskExecutor(),
            fileOperationWillBegin: byteGate.operationWillBegin
        )
        let byteDelivery = WebDAVDeliveryProbe()
        #expect(try await byteServer.submit(clientID: 91, data: options) { result in
            byteDelivery.accept(result)
        })
        try #require(await byteGate.waitUntilStarted(clientID: 91, sequence: 1))
        let byteBefore = await byteServer.diagnosticsSnapshot()
        #expect(byteBefore.currentRetainedBytes == exactRetainedLimit)
        await #expect(throws: SpiceWebDAVPipelineError.queuedRetainedBytesExceeded(
            actual: exactRetainedLimit + options.count,
            maximum: exactRetainedLimit
        )) {
            try await byteServer.submit(clientID: 92, data: options) { _ in true }
        }
        let byteAfter = await byteServer.diagnosticsSnapshot()
        #expect(byteAfter.clients == byteBefore.clients)
        #expect(byteAfter.pendingJobs == byteBefore.pendingJobs)
        #expect(byteAfter.pendingRetainedBytes == byteBefore.pendingRetainedBytes)
        #expect(byteAfter.reservedResponseBytes == byteBefore.reservedResponseBytes)
        #expect(byteAfter.currentRetainedBytes == byteBefore.currentRetainedBytes)
        #expect(byteAfter.rejectedJobs == byteBefore.rejectedJobs + 1)
        byteGate.release(clientID: 91, sequence: 1)
        try #require(await byteDelivery.waitUntilDelivered(count: 1))
        #expect(byteDelivery.outcomes.first?.responses?.count == 1)
        await waitForWebDAVServer(byteServer) {
            $0.reservedResponseBytes == 0 && $0.currentRetainedBytes == 0
        }
    }

    @Test func clientCloseDiscardsLateFilesystemResultWithoutSending() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("payload".utf8).write(to: root.appendingPathComponent("file.txt"))
        let firstKey = WebDAVOperationKey(clientID: 61, sequence: 1)
        let gate = WebDAVFileOperationGate(blocking: [firstKey])
        let executor = SpiceFilesystemTaskExecutor()
        let server = try SpiceWebDAVServer(
            root: root,
            filesystemExecutor: executor,
            fileOperationWillBegin: gate.operationWillBegin
        )
        let delivery = WebDAVDeliveryProbe()
        let get = request("GET", "/file.txt")
        #expect(try await server.submit(clientID: 61, data: get) { result in
            delivery.accept(result)
        })
        try #require(await gate.waitUntilStarted(clientID: 61, sequence: 1))
        await server.close(clientID: 61)
        gate.release(clientID: 61, sequence: 1)

        await waitForWebDAVServer(server) {
            $0.pendingJobs == 0
                && $0.currentRetainedBytes == 0
                && $0.executor.activeJobs == 0
                && $0.discardedLateResults == 1
        }
        let diagnostics = await server.diagnosticsSnapshot()
        #expect(diagnostics.clients == 0)
        #expect(diagnostics.cancelledJobs == 1)
        #expect(diagnostics.discardedLateResults == 1)
        #expect(diagnostics.executor.currentRetainedBytes == 0)
        #expect(delivery.outcomes.isEmpty)

        let reusable = try #require(await server.receive(clientID: 61, data: get).first)
        #expect(status(reusable) == 200)
        #expect(reusable.suffix(7) == Data("payload".utf8))
    }

    @Test func closeAllCancelsActiveClientsAndServerRemainsReusable() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("payload".utf8).write(to: root.appendingPathComponent("file.txt"))
        let firstKey = WebDAVOperationKey(clientID: 71, sequence: 1)
        let secondKey = WebDAVOperationKey(clientID: 72, sequence: 1)
        let gate = WebDAVFileOperationGate(blocking: [firstKey, secondKey])
        let server = try SpiceWebDAVServer(
            root: root,
            filesystemExecutor: SpiceFilesystemTaskExecutor(),
            fileOperationWillBegin: gate.operationWillBegin
        )
        let get = request("GET", "/file.txt")
        let firstDelivery = WebDAVDeliveryProbe()
        let secondDelivery = WebDAVDeliveryProbe()
        #expect(try await server.submit(clientID: 71, data: get) { result in
            firstDelivery.accept(result)
        })
        #expect(try await server.submit(clientID: 72, data: get) { result in
            secondDelivery.accept(result)
        })
        try #require(await gate.waitUntilStarted(clientID: 71, sequence: 1))
        try #require(await gate.waitUntilStarted(clientID: 72, sequence: 1))

        await server.closeAll()
        gate.release(clientID: 71, sequence: 1)
        gate.release(clientID: 72, sequence: 1)
        await waitForWebDAVServer(server) {
            $0.currentRetainedBytes == 0
                && $0.executor.activeJobs == 0
                && $0.discardedLateResults == 2
        }
        let diagnostics = await server.diagnosticsSnapshot()
        #expect(diagnostics.clients == 0)
        #expect(diagnostics.pendingJobs == 0)
        #expect(diagnostics.cancelledJobs == 2)
        #expect(diagnostics.discardedLateResults == 2)
        #expect(firstDelivery.outcomes.isEmpty)
        #expect(secondDelivery.outcomes.isEmpty)

        let reusable = try #require(await server.receive(clientID: 73, data: get).first)
        #expect(status(reusable) == 200)
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

private struct WebDAVOperationKey: Hashable, Sendable {
    let clientID: Int64
    let sequence: UInt64
}

private enum WebDAVSenderOutcome: Sendable, Equatable {
    case success([Data])
    case failure(SpiceWebDAVPipelineError)

    var responses: [Data]? {
        guard case let .success(responses) = self else { return nil }
        return responses
    }
}

private actor WebDAVResponseSenderGate {
    private(set) var outcomes: [WebDAVSenderOutcome] = []
    private var firstReleased = false
    private var firstReleaseWaiter: CheckedContinuation<Void, Never>?
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func accept(_ result: Result<[Data], SpiceWebDAVPipelineError>) async -> Bool {
        switch result {
        case let .success(responses): outcomes.append(.success(responses))
        case let .failure(error): outcomes.append(.failure(error))
        }
        let ready = countWaiters.filter { outcomes.count >= $0.0 }
        countWaiters.removeAll { outcomes.count >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
        if outcomes.count == 1, !firstReleased {
            await withCheckedContinuation { firstReleaseWaiter = $0 }
        }
        return true
    }

    func waitUntilAccepted(count: Int) async {
        guard outcomes.count < count else { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func releaseFirst() {
        firstReleased = true
        firstReleaseWaiter?.resume()
        firstReleaseWaiter = nil
    }
}

private final class WebDAVDeliveryProbe: @unchecked Sendable {
    private let storage = Mutex<[WebDAVSenderOutcome]>([])
    private let delivered = DispatchSemaphore(value: 0)

    var outcomes: [WebDAVSenderOutcome] {
        storage.withLock { $0 }
    }

    func accept(_ result: Result<[Data], SpiceWebDAVPipelineError>) -> Bool {
        storage.withLock { outcomes in
            switch result {
            case let .success(responses): outcomes.append(.success(responses))
            case let .failure(error): outcomes.append(.failure(error))
            }
        }
        delivered.signal()
        return true
    }

    func waitUntilDelivered(count: Int) async -> Bool {
        await Task.detached { [self] in
            blockingWaitUntilDelivered(count: count)
        }.value
    }

    private func blockingWaitUntilDelivered(count: Int) -> Bool {
        let deadline = DispatchTime.now() + .seconds(10)
        while storage.withLock({ $0.count }) < count {
            guard delivered.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }
}

private final class WebDAVFileOperationGate: @unchecked Sendable {
    private struct State: Sendable {
        var remainingBlocks: Set<WebDAVOperationKey>
        var releases: [WebDAVOperationKey: DispatchSemaphore]
        var started: [WebDAVOperationKey] = []
    }

    private let state: Mutex<State>
    private let operationStarted = DispatchSemaphore(value: 0)

    init(blocking keys: Set<WebDAVOperationKey>) {
        var releases: [WebDAVOperationKey: DispatchSemaphore] = [:]
        for key in keys {
            releases[key] = DispatchSemaphore(value: 0)
        }
        state = Mutex(State(remainingBlocks: keys, releases: releases))
    }

    convenience init(blocking keys: [WebDAVOperationKey]) {
        self.init(blocking: Set(keys))
    }

    var operationWillBegin: SpiceWebDAVServer.FileOperationObserver {
        { [self] clientID, sequence in
            let key = WebDAVOperationKey(clientID: clientID, sequence: sequence)
            let release: DispatchSemaphore? = state.withLock { state in
                state.started.append(key)
                guard state.remainingBlocks.remove(key) != nil else { return nil }
                return state.releases[key]
            }
            operationStarted.signal()
            release?.wait()
        }
    }

    var startedOperations: [WebDAVOperationKey] {
        state.withLock(\.started)
    }

    func waitUntilStarted(
        clientID: Int64,
        sequence: UInt64,
        timeout: DispatchTimeInterval = .seconds(10)
    ) async -> Bool {
        let key = WebDAVOperationKey(clientID: clientID, sequence: sequence)
        return await Task.detached { [self] in
            blockingWaitUntilStarted(key, timeout: timeout)
        }.value
    }

    func release(clientID: Int64, sequence: UInt64) {
        let key = WebDAVOperationKey(clientID: clientID, sequence: sequence)
        state.withLock { $0.releases[key] }?.signal()
    }

    private func blockingWaitUntilStarted(
        _ key: WebDAVOperationKey,
        timeout: DispatchTimeInterval
    ) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while !state.withLock({ $0.started.contains(key) }) {
            guard operationStarted.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }
}

private func waitForWebDAVServer(
    _ server: SpiceWebDAVServer,
    where predicate: (SpiceWebDAVServer.Diagnostics) -> Bool
) async {
    for _ in 0..<10_000 {
        if predicate(await server.diagnosticsSnapshot()) { return }
        await Task.yield()
    }
    Issue.record("WebDAV server diagnostics did not reach the expected state")
}
