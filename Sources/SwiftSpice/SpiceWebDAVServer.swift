import Foundation

public enum SpiceWebDAVAccessMode: Sendable, Equatable {
    case readOnly
    case readWrite
}

public enum SpiceWebDAVServerError: Error, Sendable, Equatable {
    case invalidRoot
    case invalidRequest
    case headerTooLarge
    case bodyTooLarge
    case tooManyClients
    case pathEscapesRoot
}

package enum SpiceWebDAVPipelineError: Error, Sendable, Equatable {
    case protocolError(SpiceWebDAVServerError)
    case tooManyPendingJobs(actual: Int, maximum: Int)
    case queuedRetainedBytesExceeded(actual: Int, maximum: Int)
    case cancelled
}

/// A bounded native WebDAV endpoint rooted at one explicitly authorized directory.
public actor SpiceWebDAVServer {
    /// All response header names and values are generated locally and fixed;
    /// none echo request text. This envelope includes status lines, every
    /// currently emitted header, a 20-digit Content-Length, and ample growth
    /// room while remaining independent from the inbound header limit.
    private static let maximumGeneratedResponseHeaderBytes = 4 * 1_024
    /// Sorting requires bounded child metadata even when names and generated
    /// fragments are individually small.
    private static let maximumPropfindChildEntries = 4_096
    package typealias FileOperationObserver = @Sendable (Int64, UInt64) -> Void
    package typealias FileBodyReadObserver = @Sendable (URL, UInt64) -> Void
    package typealias DirectoryEntryObserver = @Sendable (URL) -> Void
    package typealias ResponseSender = @Sendable (
        Result<[Data], SpiceWebDAVPipelineError>
    ) async -> Bool
    private struct Request: Sendable {
        let method: String
        let target: String
        let headers: [String: String]
        let body: Data
        let inputRetainedByteCount: Int
        let responseRetainedByteLimit: Int
        let sequence: UInt64
    }

    private struct Submission: Sendable {
        let id: UInt64
        let clientID: Int64
        let generation: UInt64
        let requests: [Request]
        let inputRetainedByteCount: Int
        let reservedResponseBytes: Int
        let responseSender: ResponseSender
    }

    private struct ClientState: Sendable {
        var generation: UInt64
        var nextSequence: UInt64 = 0
        var buffer = Data()
        var submissions: [Submission] = []
        var worker: Task<Void, Never>?
    }

    private struct ActiveResponseOwner: Sendable, Equatable {
        let generation: UInt64
        let submissionID: UInt64
    }

    private struct PropertyFragment: Sendable {
        let sortKey: String
        var data: Data?
    }

    package struct Diagnostics: Sendable, Equatable {
        package let clients: Int
        package let bufferedInputBytes: Int
        package let pendingJobs: Int
        /// Parsed request/body/header ownership awaiting completion.
        package let pendingRetainedBytes: Int
        /// Conservative encoded-response reservations, held through send.
        package let reservedResponseBytes: Int
        package let currentRetainedBytes: Int
        package let peakPendingJobs: Int
        package let peakRetainedBytes: Int
        package let completedJobs: UInt64
        package let cancelledJobs: UInt64
        /// Batch admissions rejected by a client/job/retained-byte bound.
        /// Malformed HTTP requests are protocol failures, not admission rejects.
        package let rejectedJobs: UInt64
        package let discardedLateResults: UInt64
        package let executor: SpiceFilesystemTaskExecutorDiagnostics
    }

    private struct Response: Sendable {
        let status: Int
        let reason: String
        var headers: [String: String] = [:]
        var body = Data()
        var contentLength: Int? = nil

        func encoded(includeBody: Bool = true) -> Data {
            var allHeaders = headers
            allHeaders["Content-Length"] = String(contentLength ?? body.count)
            allHeaders["Connection"] = "keep-alive"
            var text = "HTTP/1.1 \(status) \(reason)\r\n"
            for key in allHeaders.keys.sorted() {
                text += "\(key): \(allHeaders[key]!)\r\n"
            }
            text += "\r\n"
            var data = Data(text.utf8)
            if includeBody { data.append(body) }
            return data
        }
    }

    public nonisolated let root: URL
    public nonisolated let accessMode: SpiceWebDAVAccessMode
    private let maximumClients: Int
    private let maximumHeaderBytes: Int
    private nonisolated let maximumBodyBytes: Int
    private let maximumPendingJobs: Int
    private let maximumQueuedRetainedBytes: Int
    private nonisolated let filesystemExecutor: SpiceFilesystemTaskExecutor
    private nonisolated let fileOperationWillBegin: FileOperationObserver?
    private nonisolated let fileBodyWillRead: FileBodyReadObserver?
    private nonisolated let directoryEntryWasEnumerated: DirectoryEntryObserver?
    private var clients: [Int64: ClientState] = [:]
    private var legacyBuffers: [Int64: Data] = [:]
    private var legacyBufferedInputBytes = 0
    private var nextClientGeneration: UInt64 = 0
    private var nextSubmissionID: UInt64 = 0
    private var bufferedInputBytes = 0
    private var pendingJobs = 0
    private var pendingRetainedBytes = 0
    private var reservedResponseBytes = 0
    private var peakPendingJobs = 0
    private var peakRetainedBytes = 0
    private var completedJobs: UInt64 = 0
    private var cancelledJobs: UInt64 = 0
    private var rejectedJobs: UInt64 = 0
    private var discardedLateResults: UInt64 = 0
    private var activeResponseSubmissions: Set<UInt64> = []
    private var activeResponseOwners: [Int64: ActiveResponseOwner] = [:]
    private var activeFilesystemGenerations: [Int64: UInt64] = [:]
    private var activeFilesystemSubmissions: Set<UInt64> = []
    private var retiredFilesystemSubmissions: Set<UInt64> = []

    public init(
        root: URL,
        accessMode: SpiceWebDAVAccessMode = .readOnly,
        maximumClients: Int = 64,
        maximumHeaderBytes: Int = 64 * 1_024,
        maximumBodyBytes: Int = 64 * 1_024 * 1_024
    ) throws(SpiceWebDAVServerError) {
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard resolved.isFileURL,
              FileManager.default.fileExists(
                atPath: resolved.path,
                isDirectory: &isDirectory
              ),
              isDirectory.boolValue,
              maximumClients > 0,
              maximumHeaderBytes > 0,
              maximumBodyBytes >= 0 else {
            throw .invalidRoot
        }
        self.root = resolved
        self.accessMode = accessMode
        self.maximumClients = maximumClients
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumBodyBytes = maximumBodyBytes
        maximumPendingJobs = 64
        maximumQueuedRetainedBytes = 256 * 1_024 * 1_024
        filesystemExecutor = SpiceFilesystemTaskExecutor()
        fileOperationWillBegin = nil
        fileBodyWillRead = nil
        directoryEntryWasEnumerated = nil
    }

    package init(
        root: URL,
        accessMode: SpiceWebDAVAccessMode = .readOnly,
        maximumClients: Int = 64,
        maximumHeaderBytes: Int = 64 * 1_024,
        maximumBodyBytes: Int = 64 * 1_024 * 1_024,
        maximumPendingJobs: Int = 64,
        maximumQueuedRetainedBytes: Int = 256 * 1_024 * 1_024,
        filesystemExecutor: SpiceFilesystemTaskExecutor,
        fileOperationWillBegin: FileOperationObserver? = nil,
        fileBodyWillRead: FileBodyReadObserver? = nil,
        directoryEntryWasEnumerated: DirectoryEntryObserver? = nil
    ) throws(SpiceWebDAVServerError) {
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard resolved.isFileURL,
              FileManager.default.fileExists(
                atPath: resolved.path,
                isDirectory: &isDirectory
              ),
              isDirectory.boolValue,
              maximumClients > 0,
              maximumHeaderBytes > 0,
              maximumBodyBytes >= 0,
              maximumPendingJobs >= 0,
              maximumQueuedRetainedBytes >= 0 else {
            throw .invalidRoot
        }
        self.root = resolved
        self.accessMode = accessMode
        self.maximumClients = maximumClients
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumBodyBytes = maximumBodyBytes
        self.maximumPendingJobs = maximumPendingJobs
        self.maximumQueuedRetainedBytes = maximumQueuedRetainedBytes
        self.filesystemExecutor = filesystemExecutor
        self.fileOperationWillBegin = fileOperationWillBegin
        self.fileBodyWillRead = fileBodyWillRead
        self.directoryEntryWasEnumerated = directoryEntryWasEnumerated
    }

    /// Compatibility path preserving the original synchronous actor API.
    /// Production channel traffic uses the package-only bounded pipeline below.
    public func receive(
        clientID: Int64,
        data: Data
    ) throws(SpiceWebDAVServerError) -> [Data] {
        guard !data.isEmpty else {
            close(clientID: clientID)
            return []
        }
        let existingBuffer = legacyBuffers[clientID]
        if existingBuffer == nil {
            // This synchronous compatibility API cannot await retirement.
            // Reject same-ID reuse until old filesystem or response ownership
            // drains.
            guard activeFilesystemGenerations[clientID] == nil,
                  activeResponseOwners[clientID] == nil else {
                throw .invalidRequest
            }
            guard clients[clientID] == nil else { throw .invalidRequest }
            let (clientCount, overflow) = legacyBuffers.count.addingReportingOverflow(
                clients.count
            )
            guard !overflow, clientCount < maximumClients else { throw .tooManyClients }
        }
        let (candidateLegacyBytes, legacyOverflow) = legacyBufferedInputBytes
            .addingReportingOverflow(data.count)
        let currentPipelineRetained = addingSaturated(
            addingSaturated(bufferedInputBytes, pendingRetainedBytes),
            reservedResponseBytes
        )
        let (candidateTotal, totalOverflow) = currentPipelineRetained
            .addingReportingOverflow(legacyOverflow ? .max : candidateLegacyBytes)
        guard !legacyOverflow, !totalOverflow,
              candidateTotal <= maximumQueuedRetainedBytes else {
            throw .bodyTooLarge
        }
        var candidateBuffer = existingBuffer ?? Data()
        candidateBuffer.append(data)
        legacyBuffers[clientID] = candidateBuffer
        legacyBufferedInputBytes = candidateLegacyBytes
        peakRetainedBytes = max(peakRetainedBytes, candidateTotal)
        var responses: [Data] = []
        while let parsed = try nextRequest(
            buffer: legacyBuffers[clientID] ?? Data(),
            sequence: 0
        ) {
            legacyBuffers[clientID]?.removeFirst(parsed.consumedBytes)
            legacyBufferedInputBytes -= parsed.consumedBytes
            responses.append(handle(parsed.request).encoded(
                includeBody: parsed.request.method != "HEAD"
            ))
        }
        return responses
    }

    /// Admits work without awaiting filesystem access or response transmission.
    /// Returns false when the input only extends an incomplete HTTP request.
    package func submit(
        clientID: Int64,
        data: Data,
        responseSender: @escaping ResponseSender
    ) throws(SpiceWebDAVPipelineError) -> Bool {
        guard !data.isEmpty else {
            return false
        }
        return try enqueueBatch(
            clientID: clientID,
            data: data,
            responseSender: responseSender
        )
    }

    public func close(clientID: Int64) {
        if let legacyBuffer = legacyBuffers.removeValue(forKey: clientID) {
            legacyBufferedInputBytes -= legacyBuffer.count
        }
        guard let client = clients.removeValue(forKey: clientID) else { return }
        client.worker?.cancel()
        bufferedInputBytes -= client.buffer.count
        let submissions = client.submissions
        retiredFilesystemSubmissions.formUnion(
            submissions.lazy.filter { self.activeFilesystemSubmissions.contains($0.id) }
                .map(\.id)
        )
        let cancellable = submissions.filter {
            !activeResponseSubmissions.contains($0.id)
                && !activeFilesystemSubmissions.contains($0.id)
        }
        release(cancellable)
        add(&cancelledJobs, cancellable.reduce(0) { $0 + $1.requests.count })
    }

    public func closeAll() {
        legacyBuffers.removeAll(keepingCapacity: false)
        legacyBufferedInputBytes = 0
        let removed = Array(clients.values)
        clients.removeAll(keepingCapacity: false)
        bufferedInputBytes = 0
        for client in removed { client.worker?.cancel() }
        for client in removed {
            retiredFilesystemSubmissions.formUnion(
                client.submissions.lazy.filter {
                    self.activeFilesystemSubmissions.contains($0.id)
                }.map(\.id)
            )
            let cancellable = client.submissions.filter {
                !activeResponseSubmissions.contains($0.id)
                    && !activeFilesystemSubmissions.contains($0.id)
            }
            release(cancellable)
            add(&cancelledJobs, cancellable.reduce(0) { total, submission in
                total + submission.requests.count
            })
        }
    }

    package func diagnosticsSnapshot() async -> Diagnostics {
        let executor = await filesystemExecutor.diagnosticsSnapshot()
        return Diagnostics(
            clients: clients.count + legacyBuffers.count,
            bufferedInputBytes: addingSaturated(
                legacyBufferedInputBytes,
                bufferedInputBytes
            ),
            pendingJobs: pendingJobs,
            pendingRetainedBytes: pendingRetainedBytes,
            reservedResponseBytes: reservedResponseBytes,
            currentRetainedBytes: addingSaturated(
                addingSaturated(
                    addingSaturated(legacyBufferedInputBytes, bufferedInputBytes),
                    pendingRetainedBytes
                ),
                reservedResponseBytes
            ),
            peakPendingJobs: peakPendingJobs,
            peakRetainedBytes: peakRetainedBytes,
            completedJobs: completedJobs,
            cancelledJobs: cancelledJobs,
            rejectedJobs: rejectedJobs,
            discardedLateResults: discardedLateResults,
            executor: executor
        )
    }

    private func enqueueBatch(
        clientID: Int64,
        data: Data,
        responseSender: @escaping ResponseSender
    ) throws(SpiceWebDAVPipelineError) -> Bool {
        var client: ClientState
        if let existing = clients[clientID] {
            client = existing
        } else {
            guard legacyBuffers[clientID] == nil else {
                throw .protocolError(.invalidRequest)
            }
            let (clientCount, clientCountOverflow) = clients.count
                .addingReportingOverflow(legacyBuffers.count)
            guard !clientCountOverflow, clientCount < maximumClients else {
                reject()
                throw .protocolError(.tooManyClients)
            }
            guard nextClientGeneration < UInt64.max else {
                throw .protocolError(.invalidRequest)
            }
            nextClientGeneration += 1
            client = ClientState(generation: nextClientGeneration)
        }

        let (candidateCount, candidateOverflow) = client.buffer.count
            .addingReportingOverflow(data.count)
        guard !candidateOverflow else { throw .protocolError(.bodyTooLarge) }
        let retainedWithoutClientBuffer = addingSaturated(
            addingSaturated(
                addingSaturated(pendingRetainedBytes, reservedResponseBytes),
                legacyBufferedInputBytes
            ),
            bufferedInputBytes - client.buffer.count
        )
        let (candidateTotal, candidateTotalOverflow) = retainedWithoutClientBuffer
            .addingReportingOverflow(candidateCount)
        guard !candidateTotalOverflow,
              candidateTotal <= maximumQueuedRetainedBytes else {
            reject()
            throw .queuedRetainedBytesExceeded(
                actual: candidateTotalOverflow ? .max : candidateTotal,
                maximum: maximumQueuedRetainedBytes
            )
        }

        var candidateBuffer = client.buffer
        candidateBuffer.append(data)
        let parsed: ParsedRequests
        do {
            parsed = try parseRequests(
                buffer: candidateBuffer,
                nextSequence: client.nextSequence,
                maximumAdditionalRequests: max(0, maximumPendingJobs - pendingJobs)
            )
        } catch let error {
            throw .protocolError(error)
        }
        let addedJobs = parsed.requests.count
        let (actualJobs, jobOverflow) = pendingJobs.addingReportingOverflow(addedJobs)
        guard !jobOverflow, actualJobs <= maximumPendingJobs else {
            reject()
            throw .tooManyPendingJobs(
                actual: jobOverflow ? .max : actualJobs,
                maximum: maximumPendingJobs
            )
        }
        let addedInputRetained: Int
        let addedResponseReservation: Int
        do {
            addedInputRetained = try sumInputRetainedBytes(parsed.requests)
            addedResponseReservation = try sumResponseReservations(parsed.requests)
        } catch let error {
            throw .protocolError(error)
        }
        let (newPendingRetained, pendingOverflow) = pendingRetainedBytes
            .addingReportingOverflow(addedInputRetained)
        let (newResponseReservation, responseOverflow) = reservedResponseBytes
            .addingReportingOverflow(addedResponseReservation)
        let retainedOtherClients = bufferedInputBytes - client.buffer.count
        let (newBufferedInput, bufferedOverflow) = retainedOtherClients
            .addingReportingOverflow(parsed.remaining.count)
        let (newPendingTotal, pendingTotalOverflow) = newPendingRetained
            .addingReportingOverflow(newResponseReservation)
        let (withPipelineBuffers, pipelineBufferOverflow) = newPendingTotal
            .addingReportingOverflow(bufferedOverflow ? .max : newBufferedInput)
        let (newTotalRetained, totalOverflow) = withPipelineBuffers
            .addingReportingOverflow(legacyBufferedInputBytes)
        guard !pendingOverflow, !responseOverflow, !bufferedOverflow,
              !pendingTotalOverflow, !pipelineBufferOverflow, !totalOverflow,
              newTotalRetained <= maximumQueuedRetainedBytes else {
            reject()
            throw .queuedRetainedBytesExceeded(
                actual: pendingOverflow || responseOverflow || pendingTotalOverflow
                    || pipelineBufferOverflow || totalOverflow ? .max : newTotalRetained,
                maximum: maximumQueuedRetainedBytes
            )
        }

        if parsed.requests.isEmpty {
            client.buffer = parsed.remaining
            client.nextSequence = parsed.nextSequence
            bufferedInputBytes = newBufferedInput
            clients[clientID] = client
            peakRetainedBytes = max(peakRetainedBytes, newTotalRetained)
            return false
        }

        let submissionIDs = try allocatePipelineSubmissionIDs(count: parsed.requests.count)
        for (request, submissionID) in zip(parsed.requests, submissionIDs) {
            client.submissions.append(Submission(
                id: submissionID,
                clientID: clientID,
                generation: client.generation,
                requests: [request],
                inputRetainedByteCount: request.inputRetainedByteCount,
                reservedResponseBytes: request.responseRetainedByteLimit,
                responseSender: responseSender
            ))
        }
        client.buffer = parsed.remaining
        client.nextSequence = parsed.nextSequence
        bufferedInputBytes = newBufferedInput
        pendingJobs = actualJobs
        pendingRetainedBytes = newPendingRetained
        reservedResponseBytes = newResponseReservation
        peakPendingJobs = max(peakPendingJobs, pendingJobs)
        peakRetainedBytes = max(peakRetainedBytes, newTotalRetained)
        clients[clientID] = client
        startClientWorkerIfPossible(clientID: clientID)
        return true
    }

    private struct ParsedRequests {
        let requests: [Request]
        let remaining: Data
        let nextSequence: UInt64
    }

    private func parseRequests(
        buffer: Data,
        nextSequence: UInt64,
        maximumAdditionalRequests: Int
    ) throws(SpiceWebDAVServerError) -> ParsedRequests {
        var remaining = buffer
        var sequence = nextSequence
        var requests: [Request] = []
        while let parsed = try nextRequest(buffer: remaining, sequence: sequence) {
            requests.append(parsed.request)
            remaining.removeFirst(parsed.consumedBytes)
            sequence = parsed.request.sequence
            // Parsing one beyond the available admission slots is sufficient
            // to report the exact rejection without materializing an unbounded
            // request array from one pipelined input buffer.
            if requests.count > maximumAdditionalRequests { break }
        }
        return ParsedRequests(
            requests: requests,
            remaining: remaining,
            nextSequence: sequence
        )
    }

    private func nextRequest(
        buffer: Data,
        sequence: UInt64
    ) throws(SpiceWebDAVServerError) -> (request: Request, consumedBytes: Int)? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: delimiter) else {
            guard buffer.count <= maximumHeaderBytes else { throw .headerTooLarge }
            return nil
        }
        let headerLength = buffer.distance(
            from: buffer.startIndex,
            to: headerRange.upperBound
        )
        guard headerLength <= maximumHeaderBytes else { throw .headerTooLarge }
        guard let headerText = String(
            data: buffer[buffer.startIndex..<headerRange.lowerBound],
            encoding: .utf8
        ) else {
            throw .invalidRequest
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw .invalidRequest }
        let components = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count == 3,
              components[2] == "HTTP/1.1" || components[2] == "HTTP/1.0" else {
            throw .invalidRequest
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { throw .invalidRequest }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, headers.updateValue(value, forKey: key) == nil else {
                throw .invalidRequest
            }
        }
        guard headers["transfer-encoding"] == nil else { throw .invalidRequest }
        let bodyLength: Int
        if let rawLength = headers["content-length"] {
            guard let parsed = Int(rawLength), parsed >= 0 else { throw .invalidRequest }
            bodyLength = parsed
        } else {
            bodyLength = 0
        }
        guard bodyLength <= maximumBodyBytes else { throw .bodyTooLarge }
        let (requestLength, requestLengthOverflow) = headerLength
            .addingReportingOverflow(bodyLength)
        let (maximumRequestBytes, maximumOverflow) = maximumHeaderBytes
            .addingReportingOverflow(maximumBodyBytes)
        guard !requestLengthOverflow, !maximumOverflow else { throw .bodyTooLarge }
        guard buffer.count >= requestLength else {
            guard buffer.count <= maximumRequestBytes else {
                throw .bodyTooLarge
            }
            return nil
        }
        let bodyStart = headerRange.upperBound
        let bodyEnd = buffer.index(bodyStart, offsetBy: bodyLength)
        let body = Data(buffer[bodyStart..<bodyEnd])
        guard sequence < UInt64.max else { throw .invalidRequest }
        let nextSequence = sequence + 1
        let inputRetainedByteCount = try retainedByteCount(
            requestLength: requestLength,
            headerCount: headers.count
        )
        let method = String(components[0]).uppercased()
        let responseRetainedByteLimit = try responseRetainedByteLimit(for: method)
        return (Request(
            method: method,
            target: String(components[1]),
            headers: headers,
            body: body,
            inputRetainedByteCount: inputRetainedByteCount,
            responseRetainedByteLimit: responseRetainedByteLimit,
            sequence: nextSequence
        ), requestLength)
    }

    private func runClient(clientID: Int64, generation: UInt64) async {
        while !Task.isCancelled {
            guard let client = clients[clientID],
                  client.generation == generation,
                  let submission = client.submissions.first else {
                clearWorker(clientID: clientID, generation: generation)
                return
            }

            let result = await execute(submission)
            guard let current = clients[clientID],
                  current.generation == generation,
                  current.submissions.first?.id == submission.id else {
                if retiredFilesystemSubmissions.remove(submission.id) != nil {
                    release([submission])
                    add(&cancelledJobs, submission.requests.count)
                }
                add(&discardedLateResults, submission.requests.count)
                return
            }
            // The response reservation remains charged while the sender owns
            // the result. This bounds slow-client response retention without
            // holding a filesystem executor permit during transport I/O.
            let responseOwner = ActiveResponseOwner(
                generation: generation,
                submissionID: submission.id
            )
            precondition(activeResponseOwners[clientID] == nil)
            precondition(activeResponseSubmissions.insert(submission.id).inserted)
            activeResponseOwners[clientID] = responseOwner
            clients[clientID] = current
            let delivered = await submission.responseSender(result)

            guard finishResponseDelivery(submission, owner: responseOwner) else {
                return
            }
            // This is the sole handoff for same-ID reuse after response
            // retirement. Admission may already have installed a newer
            // generation, but it cannot start until ownership is released.
            defer { startClientWorkerIfPossible(clientID: clientID) }
            if var latest = clients[clientID],
               latest.generation == generation,
               latest.submissions.first?.id == submission.id {
                latest.submissions.removeFirst()
                clients[clientID] = latest
            }
            switch (result, delivered) {
            case (.success, true):
                add(&completedJobs, submission.requests.count)
            case (.failure(.cancelled), _), (_, false):
                add(&cancelledJobs, submission.requests.count)
            case (.failure, true):
                break
            }
            if !delivered {
                terminateClientPump(clientID: clientID, generation: generation)
                return
            }
            if Task.isCancelled {
                return
            }
        }
    }

    private func execute(
        _ submission: Submission
    ) async -> Result<[Data], SpiceWebDAVPipelineError> {
        var responses: [Data] = []
        responses.reserveCapacity(submission.requests.count)
        for request in submission.requests {
            guard beginFilesystemOperation(submission) else {
                return .failure(.cancelled)
            }
            let executionResult: Result<Data, SpiceFilesystemTaskExecutorError>
            do {
                executionResult = .success(try await filesystemExecutor.execute(
                    retainedByteCount: request.inputRetainedByteCount
                ) { [self] in
                    fileOperationWillBegin?(submission.clientID, request.sequence)
                    return handle(request).encoded(includeBody: request.method != "HEAD")
                })
            } catch let error {
                executionResult = .failure(error)
            }
            finishFilesystemOperation(submission)
            switch executionResult {
            case let .success(response):
                guard response.count <= request.responseRetainedByteLimit else {
                    return .failure(.protocolError(.bodyTooLarge))
                }
                responses.append(response)
            case let .failure(error):
                return .failure(map(executorError: error))
            }
        }
        return .success(responses)
    }

    private func beginFilesystemOperation(_ submission: Submission) -> Bool {
        guard !Task.isCancelled,
              activeFilesystemGenerations[submission.clientID] == nil,
              clients[submission.clientID]?.generation == submission.generation,
              clients[submission.clientID]?.submissions.first?.id == submission.id else {
            return false
        }
        activeFilesystemGenerations[submission.clientID] = submission.generation
        activeFilesystemSubmissions.insert(submission.id)
        return true
    }

    private func finishFilesystemOperation(_ submission: Submission) {
        guard activeFilesystemGenerations[submission.clientID] == submission.generation,
              activeFilesystemSubmissions.remove(submission.id) != nil else {
            return
        }
        activeFilesystemGenerations.removeValue(forKey: submission.clientID)
        // If close/reuse installed a newer generation while the old syscall
        // drained, this is the sole point that starts its pump. Waiting never
        // consumes an executor permit or blocks this actor.
        startClientWorkerIfPossible(clientID: submission.clientID)
    }

    private func startClientWorkerIfPossible(clientID: Int64) {
        guard activeFilesystemGenerations[clientID] == nil,
              activeResponseOwners[clientID] == nil,
              var client = clients[clientID],
              client.worker == nil,
              !client.submissions.isEmpty else {
            return
        }
        let generation = client.generation
        client.worker = Task { [weak self] in
            await self?.runClient(clientID: clientID, generation: generation)
        }
        clients[clientID] = client
    }

    private func finishResponseDelivery(
        _ submission: Submission,
        owner: ActiveResponseOwner
    ) -> Bool {
        guard activeResponseSubmissions.contains(submission.id),
              activeResponseOwners[submission.clientID] == owner else {
            return false
        }
        activeResponseSubmissions.remove(submission.id)
        activeResponseOwners.removeValue(forKey: submission.clientID)
        release([submission])
        return true
    }

    private func clearWorker(clientID: Int64, generation: UInt64) {
        guard var client = clients[clientID], client.generation == generation else { return }
        client.worker = nil
        clients[clientID] = client
    }

    /// A failed response handoff terminates the ordered client pipeline. Any
    /// later request may be mutating, so it must never execute after its
    /// predecessor could not be delivered.
    private func terminateClientPump(clientID: Int64, generation: UInt64) {
        guard let client = clients[clientID], client.generation == generation else {
            return
        }
        clients.removeValue(forKey: clientID)
        bufferedInputBytes -= client.buffer.count
        release(client.submissions)
        add(&cancelledJobs, client.submissions.reduce(0) {
            $0 + $1.requests.count
        })
    }

    private func release(_ submissions: [Submission]) {
        for submission in submissions {
            pendingJobs -= submission.requests.count
            pendingRetainedBytes -= submission.inputRetainedByteCount
            reservedResponseBytes -= submission.reservedResponseBytes
        }
    }

    private func allocatePipelineSubmissionIDs(
        count: Int
    ) throws(SpiceWebDAVPipelineError) -> Range<UInt64> {
        guard count > 0,
              let unsignedCount = UInt64(exactly: count) else {
            throw .protocolError(.invalidRequest)
        }
        let (end, overflow) = nextSubmissionID.addingReportingOverflow(unsignedCount)
        guard !overflow else { throw .protocolError(.invalidRequest) }
        let start = nextSubmissionID
        nextSubmissionID = end
        return start..<end
    }

    private func retainedByteCount(
        requestLength: Int,
        headerCount: Int
    ) throws(SpiceWebDAVServerError) -> Int {
        let (headerMetadata, headerOverflow) = headerCount.multipliedReportingOverflow(by: 128)
        let (withHeaders, requestOverflow) = requestLength.addingReportingOverflow(
            headerOverflow ? .max : headerMetadata
        )
        let (total, fixedOverflow) = withHeaders.addingReportingOverflow(512)
        guard !headerOverflow, !requestOverflow, !fixedOverflow else {
            throw .bodyTooLarge
        }
        return total
    }

    private func responseRetainedByteLimit(
        for method: String
    ) throws(SpiceWebDAVServerError) -> Int {
        // Body-bearing reads reserve their configured body ceiling. Other
        // responses are generated solely from bounded headers/status text.
        let bodyLimit = method == "GET" || method == "PROPFIND"
            ? maximumBodyBytes
            : 0
        let (total, overflow) = Self.maximumGeneratedResponseHeaderBytes
            .addingReportingOverflow(bodyLimit)
        guard !overflow else { throw .bodyTooLarge }
        return total
    }

    private func sumInputRetainedBytes(
        _ requests: [Request]
    ) throws(SpiceWebDAVServerError) -> Int {
        var total = 0
        for request in requests {
            let (next, overflow) = total.addingReportingOverflow(
                request.inputRetainedByteCount
            )
            guard !overflow else { throw .bodyTooLarge }
            total = next
        }
        return total
    }

    private func sumResponseReservations(
        _ requests: [Request]
    ) throws(SpiceWebDAVServerError) -> Int {
        var total = 0
        for request in requests {
            let (next, overflow) = total.addingReportingOverflow(
                request.responseRetainedByteLimit
            )
            guard !overflow else { throw .bodyTooLarge }
            total = next
        }
        return total
    }

    private func map(
        executorError: SpiceFilesystemTaskExecutorError
    ) -> SpiceWebDAVPipelineError {
        switch executorError {
        case let .tooManyPendingJobs(actual, maximum):
            .tooManyPendingJobs(actual: actual, maximum: maximum)
        case let .queuedRetainedBytesExceeded(actual, maximum):
            .queuedRetainedBytesExceeded(actual: actual, maximum: maximum)
        case .cancelled, .closed:
            .cancelled
        case .invalidLimits, .invalidRetainedByteCount:
            .protocolError(.invalidRequest)
        }
    }

    private func reject() {
        add(&rejectedJobs, 1)
    }

    private func addingSaturated(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }

    private func add(_ value: inout UInt64, _ increment: Int) {
        guard increment > 0 else { return }
        let (next, overflow) = value.addingReportingOverflow(UInt64(increment))
        value = overflow ? .max : next
    }

    private nonisolated func handle(_ request: Request) -> Response {
        // Keep resolution and the filesystem operation in one synchronous
        // executor job. FileManager never crosses an isolation boundary.
        let fileManager = FileManager()
        do {
            switch request.method {
            case "OPTIONS":
                let methods = accessMode == .readOnly
                    ? "OPTIONS, PROPFIND, GET, HEAD"
                    : "OPTIONS, PROPFIND, GET, HEAD, PUT, MKCOL, DELETE, COPY, MOVE"
                return Response(
                    status: 200,
                    reason: "OK",
                    headers: [
                        "Allow": methods,
                        "DAV": "1",
                    ]
                )
            case "PROPFIND":
                return try propfind(request, fileManager: fileManager)
            case "GET":
                return try get(request, includeBody: true, fileManager: fileManager)
            case "HEAD":
                return try get(request, includeBody: false, fileManager: fileManager)
            case "PUT":
                return try put(request, fileManager: fileManager)
            case "MKCOL":
                return try makeCollection(request, fileManager: fileManager)
            case "DELETE":
                return try delete(request, fileManager: fileManager)
            case "COPY", "MOVE":
                return try copyOrMove(request, fileManager: fileManager)
            default:
                return Response(status: 405, reason: "Method Not Allowed")
            }
        } catch SpiceWebDAVServerError.pathEscapesRoot {
            return Response(status: 403, reason: "Forbidden")
        } catch {
            return Response(status: 500, reason: "Internal Server Error")
        }
    }

    private nonisolated func propfind(
        _ request: Request,
        fileManager: FileManager
    ) throws -> Response {
        let url = try resolve(request.target, mayNotExist: false, fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.path) else {
            return Response(status: 404, reason: "Not Found")
        }
        let depth = request.headers["depth"] ?? "infinity"
        guard depth == "0" || depth == "1" else {
            return Response(status: 403, reason: "Forbidden")
        }
        let prefix = Data(
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>".utf8
        ) + Data("<D:multistatus xmlns:D=\"DAV:\">".utf8)
        let suffix = Data("</D:multistatus>".utf8)
        let rootFragment = Data(try propertyResponse(
            url,
            fileManager: fileManager
        ).utf8)
        guard let rootBodyBytes = checkedPropertyBodySize(
            current: prefix.count,
            adding: rootFragment.count,
            suffix: suffix.count
        ) else {
            return Response(status: 507, reason: "Insufficient Storage")
        }

        var bodyBytes = rootBodyBytes - suffix.count
        var childFragments: [PropertyFragment] = []
        if depth == "1", isDirectory(url, fileManager: fileManager) {
            var enumerationFailure: (any Error)?
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                errorHandler: { _, error in
                    enumerationFailure = error
                    return false
                }
            ) else {
                throw SpiceWebDAVServerError.invalidRequest
            }
            while let value = enumerator.nextObject() {
                guard let childURL = value as? URL else {
                    throw SpiceWebDAVServerError.invalidRequest
                }
                directoryEntryWasEnumerated?(childURL)
                guard childFragments.count < Self.maximumPropfindChildEntries else {
                    return Response(status: 507, reason: "Insufficient Storage")
                }
                let fragment = Data(try propertyResponse(
                    childURL,
                    fileManager: fileManager
                ).utf8)
                guard let nextBodyBytes = checkedPropertyBodySize(
                    current: bodyBytes,
                    adding: fragment.count,
                    suffix: suffix.count
                ) else {
                    return Response(status: 507, reason: "Insufficient Storage")
                }
                bodyBytes = nextBodyBytes - suffix.count
                childFragments.append(PropertyFragment(
                    sortKey: childURL.lastPathComponent,
                    data: fragment
                ))
            }
            if let enumerationFailure {
                throw enumerationFailure
            }
        }

        childFragments.sort { lhs, rhs in
            lhs.sortKey < rhs.sortKey
        }
        var xml = prefix
        xml.append(rootFragment)
        for index in childFragments.indices {
            guard let fragment = childFragments[index].data else {
                preconditionFailure("property fragment consumed more than once")
            }
            childFragments[index].data = nil
            xml.append(fragment)
        }
        xml.append(suffix)
        precondition(xml.count == bodyBytes + suffix.count)
        return Response(
            status: 207,
            reason: "Multi-Status",
            headers: ["Content-Type": "application/xml; charset=utf-8"],
            body: xml
        )
    }

    private nonisolated func checkedPropertyBodySize(
        current: Int,
        adding: Int,
        suffix: Int
    ) -> Int? {
        let (withEntry, entryOverflow) = current.addingReportingOverflow(adding)
        let (finalSize, finalOverflow) = withEntry.addingReportingOverflow(suffix)
        guard !entryOverflow, !finalOverflow, finalSize <= maximumBodyBytes else {
            return nil
        }
        return finalSize
    }

    private nonisolated func get(
        _ request: Request,
        includeBody: Bool,
        fileManager: FileManager
    ) throws -> Response {
        let url = try resolve(request.target, mayNotExist: false, fileManager: fileManager)
        var directory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &directory) else {
            return Response(status: 404, reason: "Not Found")
        }
        guard !directory.boolValue else {
            return Response(status: 405, reason: "Method Not Allowed")
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size <= UInt64(maximumBodyBytes) else {
            return Response(status: 413, reason: "Content Too Large")
        }
        guard let contentLength = Int(exactly: size) else {
            return Response(status: 413, reason: "Content Too Large")
        }
        guard includeBody else {
            // Opening the resolved file preserves GET's access validation
            // without mapping or copying its contents into retained memory.
            let file = try FileHandle(forReadingFrom: url)
            try file.close()
            return Response(
                status: 200,
                reason: "OK",
                headers: ["Content-Type": "application/octet-stream"],
                contentLength: contentLength
            )
        }
        fileBodyWillRead?(url, size)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return Response(
            status: 200,
            reason: "OK",
            headers: ["Content-Type": "application/octet-stream"],
            body: data
        )
    }

    private nonisolated func put(
        _ request: Request,
        fileManager: FileManager
    ) throws -> Response {
        guard accessMode == .readWrite else {
            return Response(status: 403, reason: "Forbidden")
        }
        let url = try resolve(request.target, mayNotExist: true, fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.deletingLastPathComponent().path) else {
            return Response(status: 409, reason: "Conflict")
        }
        var directory: ObjCBool = false
        let existed = fileManager.fileExists(atPath: url.path, isDirectory: &directory)
        guard !directory.boolValue else {
            return Response(status: 405, reason: "Method Not Allowed")
        }
        try request.body.write(to: url, options: [.atomic])
        return Response(status: existed ? 204 : 201, reason: existed ? "No Content" : "Created")
    }

    private nonisolated func makeCollection(
        _ request: Request,
        fileManager: FileManager
    ) throws -> Response {
        guard accessMode == .readWrite else {
            return Response(status: 403, reason: "Forbidden")
        }
        guard request.body.isEmpty else {
            return Response(status: 415, reason: "Unsupported Media Type")
        }
        let url = try resolve(request.target, mayNotExist: true, fileManager: fileManager)
        guard !fileManager.fileExists(atPath: url.path) else {
            return Response(status: 405, reason: "Method Not Allowed")
        }
        guard fileManager.fileExists(atPath: url.deletingLastPathComponent().path) else {
            return Response(status: 409, reason: "Conflict")
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return Response(status: 201, reason: "Created")
    }

    private nonisolated func delete(
        _ request: Request,
        fileManager: FileManager
    ) throws -> Response {
        guard accessMode == .readWrite else {
            return Response(status: 403, reason: "Forbidden")
        }
        let url = try resolve(request.target, mayNotExist: false, fileManager: fileManager)
        guard url != root else { return Response(status: 403, reason: "Forbidden") }
        guard fileManager.fileExists(atPath: url.path) else {
            return Response(status: 404, reason: "Not Found")
        }
        try fileManager.removeItem(at: url)
        return Response(status: 204, reason: "No Content")
    }

    private nonisolated func copyOrMove(
        _ request: Request,
        fileManager: FileManager
    ) throws -> Response {
        guard accessMode == .readWrite else {
            return Response(status: 403, reason: "Forbidden")
        }
        guard let destination = request.headers["destination"] else {
            return Response(status: 400, reason: "Bad Request")
        }
        let source = try resolve(
            request.target,
            mayNotExist: false,
            fileManager: fileManager
        )
        let target = try resolve(
            destination,
            mayNotExist: true,
            fileManager: fileManager
        )
        guard source != root, target != root,
              fileManager.fileExists(atPath: source.path) else {
            return Response(status: 404, reason: "Not Found")
        }
        guard !isDirectory(source, fileManager: fileManager) else {
            return Response(status: 405, reason: "Method Not Allowed")
        }
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size <= UInt64(maximumBodyBytes) else {
            return Response(status: 413, reason: "Content Too Large")
        }
        guard fileManager.fileExists(atPath: target.deletingLastPathComponent().path) else {
            return Response(status: 409, reason: "Conflict")
        }
        let existed = fileManager.fileExists(atPath: target.path)
        if existed {
            guard request.headers["overwrite"]?.uppercased() != "F" else {
                return Response(status: 412, reason: "Precondition Failed")
            }
            try fileManager.removeItem(at: target)
        }
        if request.method == "COPY" {
            try fileManager.copyItem(at: source, to: target)
        } else {
            try fileManager.moveItem(at: source, to: target)
        }
        return Response(status: existed ? 204 : 201, reason: existed ? "No Content" : "Created")
    }

    private nonisolated func resolve(
        _ requestTarget: String,
        mayNotExist: Bool,
        fileManager: FileManager
    ) throws(SpiceWebDAVServerError) -> URL {
        let path: String
        if let components = URLComponents(string: requestTarget),
           requestTarget.contains("://") {
            path = components.percentEncodedPath.removingPercentEncoding ?? ""
        } else {
            path = requestTarget.split(separator: "?", maxSplits: 1).first
                .map(String.init)?.removingPercentEncoding ?? ""
        }
        guard path.hasPrefix("/") else { throw .invalidRequest }
        guard path.unicodeScalars.allSatisfy({ scalar in
            scalar.value >= 0x20 && scalar.value != 0x7f
        }) else {
            throw .invalidRequest
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("."), !components.contains("..") else {
            throw .pathEscapesRoot
        }
        var candidate = root
        for component in components {
            candidate.appendPathComponent(String(component), isDirectory: false)
        }
        candidate = candidate.standardizedFileURL
        let exists = fileManager.fileExists(atPath: candidate.path)
        let checked = exists || !mayNotExist
            ? candidate.resolvingSymlinksInPath()
            : candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        guard contains(checked), contains(candidate.standardizedFileURL) else {
            throw .pathEscapesRoot
        }
        return candidate
    }

    private nonisolated func contains(_ url: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    private nonisolated func isDirectory(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }

    private nonisolated func propertyResponse(
        _ url: URL,
        fileManager: FileManager
    ) throws -> String {
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(resolvedURL) else {
            throw SpiceWebDAVServerError.pathEscapesRoot
        }
        let attributes = try fileManager.attributesOfItem(atPath: resolvedURL.path)
        let directory = attributes[.type] as? FileAttributeType == .typeDirectory
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationDate = attributes[.modificationDate] as? Date
            ?? Date(timeIntervalSince1970: 0)
        let modificationSeconds = Int64(modificationDate.timeIntervalSince1970)
        let etag = "\"\(String(size, radix: 16))-\(String(modificationSeconds, radix: 16))\""
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let lastModified = dateFormatter.string(from: modificationDate)
        let relative = resolvedURL.path == root.path
            ? "/"
            : "/" + resolvedURL.path.dropFirst(root.path.count + 1)
        var href = String(relative).addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? String(relative)
        if directory, href != "/", !href.hasSuffix("/") {
            href += "/"
        }
        href = xmlEscape(href)
        let displayName = xmlEscape(
            resolvedURL.path == root.path ? "/" : resolvedURL.lastPathComponent
        )
        let resourceType = directory ? "<D:collection/>" : ""
        return "<D:response><D:href>\(href)</D:href><D:propstat><D:prop>" +
            "<D:displayname>\(displayName)</D:displayname>" +
            "<D:resourcetype>\(resourceType)</D:resourcetype>" +
            "<D:getcontentlength>\(size)</D:getcontentlength>" +
            "<D:getetag>\(xmlEscape(etag))</D:getetag>" +
            "<D:getlastmodified>\(xmlEscape(lastModified))</D:getlastmodified>" +
            "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
    }

    private nonisolated func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
