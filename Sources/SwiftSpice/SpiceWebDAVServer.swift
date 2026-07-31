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

/// A bounded native WebDAV endpoint rooted at one explicitly authorized directory.
public actor SpiceWebDAVServer {
    private struct Request: Sendable {
        let method: String
        let target: String
        let headers: [String: String]
        let body: Data
    }

    private struct Response: Sendable {
        let status: Int
        let reason: String
        var headers: [String: String] = [:]
        var body = Data()

        func encoded(includeBody: Bool = true) -> Data {
            var allHeaders = headers
            allHeaders["Content-Length"] = String(body.count)
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
    private let maximumBodyBytes: Int
    private var buffers: [Int64: Data] = [:]
    private let fileManager = FileManager()

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
    }

    /// Incrementally consumes one HTTP byte stream and returns complete responses.
    public func receive(
        clientID: Int64,
        data: Data
    ) throws(SpiceWebDAVServerError) -> [Data] {
        guard !data.isEmpty else {
            buffers.removeValue(forKey: clientID)
            return []
        }
        if buffers[clientID] == nil {
            guard buffers.count < maximumClients else { throw .tooManyClients }
            buffers[clientID] = Data()
        }
        buffers[clientID]!.append(data)
        var responses: [Data] = []
        while let request = try nextRequest(clientID: clientID) {
            responses.append(handle(request).encoded(includeBody: request.method != "HEAD"))
        }
        return responses
    }

    public func close(clientID: Int64) {
        buffers.removeValue(forKey: clientID)
    }

    public func closeAll() {
        buffers.removeAll(keepingCapacity: false)
    }

    private func nextRequest(clientID: Int64) throws(SpiceWebDAVServerError) -> Request? {
        guard var buffer = buffers[clientID] else { return nil }
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
        guard buffer.count >= headerLength + bodyLength else {
            guard buffer.count <= maximumHeaderBytes + maximumBodyBytes else {
                throw .bodyTooLarge
            }
            return nil
        }
        let bodyStart = headerRange.upperBound
        let bodyEnd = buffer.index(bodyStart, offsetBy: bodyLength)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer.removeFirst(headerLength + bodyLength)
        buffers[clientID] = buffer
        return Request(
            method: String(components[0]).uppercased(),
            target: String(components[1]),
            headers: headers,
            body: body
        )
    }

    private func handle(_ request: Request) -> Response {
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
                return try propfind(request)
            case "GET", "HEAD":
                return try get(request)
            case "PUT":
                return try put(request)
            case "MKCOL":
                return try makeCollection(request)
            case "DELETE":
                return try delete(request)
            case "COPY", "MOVE":
                return try copyOrMove(request)
            default:
                return Response(status: 405, reason: "Method Not Allowed")
            }
        } catch SpiceWebDAVServerError.pathEscapesRoot {
            return Response(status: 403, reason: "Forbidden")
        } catch {
            return Response(status: 500, reason: "Internal Server Error")
        }
    }

    private func propfind(_ request: Request) throws -> Response {
        let url = try resolve(request.target, mayNotExist: false)
        guard fileManager.fileExists(atPath: url.path) else {
            return Response(status: 404, reason: "Not Found")
        }
        let depth = request.headers["depth"] ?? "infinity"
        guard depth == "0" || depth == "1" else {
            return Response(status: 403, reason: "Forbidden")
        }
        var urls = [url]
        if depth == "1", isDirectory(url) {
            urls += try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        let entries = try urls.map(propertyResponse).joined()
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
            "<D:multistatus xmlns:D=\"DAV:\">\(entries)</D:multistatus>"
        return Response(
            status: 207,
            reason: "Multi-Status",
            headers: ["Content-Type": "application/xml; charset=utf-8"],
            body: Data(xml.utf8)
        )
    }

    private func get(_ request: Request) throws -> Response {
        let url = try resolve(request.target, mayNotExist: false)
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
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return Response(
            status: 200,
            reason: "OK",
            headers: ["Content-Type": "application/octet-stream"],
            body: data
        )
    }

    private func put(_ request: Request) throws -> Response {
        guard accessMode == .readWrite else {
            return Response(status: 403, reason: "Forbidden")
        }
        let url = try resolve(request.target, mayNotExist: true)
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

    private func makeCollection(_ request: Request) throws -> Response {
        guard accessMode == .readWrite else {
            return Response(status: 403, reason: "Forbidden")
        }
        guard request.body.isEmpty else {
            return Response(status: 415, reason: "Unsupported Media Type")
        }
        let url = try resolve(request.target, mayNotExist: true)
        guard !fileManager.fileExists(atPath: url.path) else {
            return Response(status: 405, reason: "Method Not Allowed")
        }
        guard fileManager.fileExists(atPath: url.deletingLastPathComponent().path) else {
            return Response(status: 409, reason: "Conflict")
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return Response(status: 201, reason: "Created")
    }

    private func delete(_ request: Request) throws -> Response {
        guard accessMode == .readWrite else {
            return Response(status: 403, reason: "Forbidden")
        }
        let url = try resolve(request.target, mayNotExist: false)
        guard url != root else { return Response(status: 403, reason: "Forbidden") }
        guard fileManager.fileExists(atPath: url.path) else {
            return Response(status: 404, reason: "Not Found")
        }
        try fileManager.removeItem(at: url)
        return Response(status: 204, reason: "No Content")
    }

    private func copyOrMove(_ request: Request) throws -> Response {
        guard accessMode == .readWrite else {
            return Response(status: 403, reason: "Forbidden")
        }
        guard let destination = request.headers["destination"] else {
            return Response(status: 400, reason: "Bad Request")
        }
        let source = try resolve(request.target, mayNotExist: false)
        let target = try resolve(destination, mayNotExist: true)
        guard source != root, target != root,
              fileManager.fileExists(atPath: source.path) else {
            return Response(status: 404, reason: "Not Found")
        }
        guard !isDirectory(source) else {
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

    private func resolve(
        _ requestTarget: String,
        mayNotExist: Bool
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

    private func contains(_ url: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }

    private func propertyResponse(_ url: URL) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let directory = attributes[.type] as? FileAttributeType == .typeDirectory
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let relative = url.path == root.path
            ? "/"
            : "/" + url.path.dropFirst(root.path.count + 1)
        let href = xmlEscape(String(relative).addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? String(relative)) + (directory ? "/" : "")
        let displayName = xmlEscape(url == root ? root.lastPathComponent : url.lastPathComponent)
        let resourceType = directory ? "<D:collection/>" : ""
        return "<D:response><D:href>\(href)</D:href><D:propstat><D:prop>" +
            "<D:displayname>\(displayName)</D:displayname>" +
            "<D:resourcetype>\(resourceType)</D:resourcetype>" +
            "<D:getcontentlength>\(size)</D:getcontentlength>" +
            "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
