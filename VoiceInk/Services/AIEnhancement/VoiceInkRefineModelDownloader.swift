import CryptoKit
import Foundation

struct VoiceInkRefineDownloadProgress: Sendable {
    let downloadedBytes: Int64
    let totalBytes: Int64
    let isFinalizing: Bool
}

enum VoiceInkRefineDownloadError: LocalizedError {
    case invalidDownloadURL(String)
    case invalidResponse(String)
    case unexpectedStatusCode(Int, String)
    case invalidContentRange(String)
    case invalidFileSize(String, expected: Int64, actual: Int64)
    case invalidChecksum(String)

    var errorDescription: String? {
        switch self {
        case let .invalidDownloadURL(path):
            return String(localized: "Could not create the download URL for \(path).")
        case let .invalidResponse(path):
            return String(localized: "The model server returned an invalid response for \(path).")
        case let .unexpectedStatusCode(statusCode, path):
            return String(localized: "The model server returned status \(statusCode) for \(path).")
        case let .invalidContentRange(path):
            return String(localized: "The model server returned an invalid byte range for \(path).")
        case let .invalidFileSize(path, expected, actual):
            return String(
                localized: "The downloaded size for \(path) was \(actual) bytes instead of \(expected) bytes."
            )
        case let .invalidChecksum(path):
            return String(localized: "The downloaded file for \(path) failed integrity verification.")
        }
    }
}

final class VoiceInkRefineModelDownloader: @unchecked Sendable {
    /// Manifest entry type. Models and their pinned file lists live in
    /// `LocalMLXModelCatalog`.
    typealias ModelFile = LocalMLXModelFile

    private struct SnapshotVerificationRecord: Codable, Equatable {
        let version: Int
        let files: [SnapshotFileVerificationRecord]
    }

    private struct SnapshotFileVerificationRecord: Codable, Equatable {
        let path: String
        let size: Int64
        let expectedSHA256: String?
        let modificationTime: TimeInterval
    }

    private static let verificationRecordVersion = 1
    private static let verificationRecordFilename = ".voiceink-integrity.json"

    /// The original model predates the catalog and sits at the root of the
    /// model directory, so it keeps that location and existing downloads stay
    /// valid. Every other model gets its own subdirectory.
    static func snapshotDirectory(
        in modelRootDirectory: URL,
        model: LocalMLXModel
    ) -> URL {
        model.usesLegacyRootDirectory
            ? modelRootDirectory
            : modelRootDirectory.appendingPathComponent(model.id, isDirectory: true)
    }

    static func isSnapshotComplete(
        at snapshotDirectory: URL,
        model: LocalMLXModel
    ) -> Bool {
        isSnapshotComplete(at: snapshotDirectory, files: model.files)
    }

    static func isSnapshotComplete(
        at snapshotDirectory: URL,
        files: [ModelFile]
    ) -> Bool {
        guard let currentRecord = verificationRecord(
            at: snapshotDirectory,
            files: files
        ) else {
            return false
        }

        let recordURL = snapshotDirectory.appendingPathComponent(verificationRecordFilename)
        if !FileManager.default.fileExists(atPath: recordURL.path) {
            // Existing installations use the original size-based completion check.
            return true
        }

        if storedVerificationRecord(at: snapshotDirectory) == currentRecord {
            return true
        }

        do {
            for file in files {
                try validateDownloadedFile(
                    at: snapshotDirectory.appendingPathComponent(file.path),
                    file: file
                )
            }
            try? persistVerificationRecord(currentRecord, at: snapshotDirectory)
            return true
        } catch {
            return false
        }
    }

    private let repositoryID: String
    private let revision: String
    private let files: [ModelFile]
    private let snapshotDirectory: URL
    private let partialsDirectory: URL
    private let progressTracker: ProgressTracker
    private let maximumAttempts = 4

    init(model: LocalMLXModel, modelRootDirectory: URL) {
        repositoryID = model.repositoryID
        revision = model.revision
        files = model.files
        progressTracker = ProgressTracker(totalBytes: model.totalBytes)
        snapshotDirectory = Self.snapshotDirectory(
            in: modelRootDirectory,
            model: model
        )
        partialsDirectory = modelRootDirectory
            .appendingPathComponent(".voiceink-download-\(model.revision)", isDirectory: true)
    }

    var progress: VoiceInkRefineDownloadProgress {
        progressTracker.snapshot()
    }

    func download() async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: snapshotDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: partialsDirectory,
            withIntermediateDirectories: true
        )

        let pendingFiles = try prepareFiles()
        for file in pendingFiles {
            try Task.checkCancellation()
            try await download(file)
        }

        try Task.checkCancellation()
        progressTracker.beginFinalizing()
        try validateSnapshot()

        if FileManager.default.fileExists(atPath: partialsDirectory.path) {
            try FileManager.default.removeItem(at: partialsDirectory)
        }
    }

    private func prepareFiles() throws -> [ModelFile] {
        var pendingFiles: [ModelFile] = []

        for file in files {
            try Task.checkCancellation()

            let finalURL = snapshotDirectory.appendingPathComponent(file.path)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                do {
                    try Self.validateDownloadedFile(at: finalURL, file: file)
                    progressTracker.update(identifier: file.path, downloadedBytes: file.size)
                    continue
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try FileManager.default.removeItem(at: finalURL)
                }
            }

            let partialURL = partialURL(for: file)
            let partialSize = Self.fileSize(at: partialURL) ?? 0
            if partialSize > file.size {
                clearPartialDownload(for: file)
                progressTracker.update(identifier: file.path, downloadedBytes: 0)
            } else {
                progressTracker.update(identifier: file.path, downloadedBytes: partialSize)
            }

            pendingFiles.append(file)
        }

        return pendingFiles
    }

    private func download(_ file: ModelFile) async throws {
        var attempt = 1

        while true {
            try Task.checkCancellation()

            do {
                try await performDownload(file)
                return
            } catch {
                if Task.isCancelled || Self.isCancellation(error) {
                    throw CancellationError()
                }

                guard attempt < maximumAttempts, Self.isTransient(error) else {
                    throw error
                }

                let delay = min(pow(2, Double(attempt - 1)), 4)
                attempt += 1
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func performDownload(_ file: ModelFile) async throws {
        let partialURL = partialURL(for: file)
        let validatorURL = validatorURL(for: file)

        try FileManager.default.createDirectory(
            at: partialURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var partialSize = Self.fileSize(at: partialURL) ?? 0
        if partialSize == file.size {
            do {
                try Self.validateDownloadedFile(at: partialURL, file: file)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                clearPartialDownload(for: file)
                partialSize = 0
                progressTracker.update(identifier: file.path, downloadedBytes: 0)
            }

            if partialSize == file.size {
                try installDownloadedFile(at: partialURL, file: file)
                return
            }
        }

        if partialSize > file.size {
            clearPartialDownload(for: file)
            partialSize = 0
            progressTracker.update(identifier: file.path, downloadedBytes: 0)
        }

        guard let url = downloadURL(for: file) else {
            throw VoiceInkRefineDownloadError.invalidDownloadURL(file.path)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 24 * 60 * 60
        request.setValue("VoiceInk", forHTTPHeaderField: "User-Agent")

        var resumeOffset: Int64 = 0
        let validator = (
            try? String(contentsOf: validatorURL, encoding: .utf8)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        if partialSize > 0, let validator, !validator.isEmpty {
            request.setValue("bytes=\(partialSize)-", forHTTPHeaderField: "Range")
            request.setValue(validator, forHTTPHeaderField: "If-Range")
            resumeOffset = partialSize
        } else if partialSize > 0 {
            clearPartialDownload(for: file)
            partialSize = 0
            progressTracker.update(identifier: file.path, downloadedBytes: 0)
        }

        let response = try await streamDownload(
            request: request,
            to: partialURL,
            file: file,
            resumeOffset: resumeOffset,
            onProgress: { [progressTracker] downloadedBytes in
                progressTracker.update(
                    identifier: file.path,
                    downloadedBytes: downloadedBytes
                )
            },
            onResponse: { [weak self] response in
                guard response.statusCode != 206 else {
                    return
                }
                self?.persistResumeValidator(
                    from: response,
                    to: validatorURL
                )
            }
        )

        if response.statusCode == 416 {
            clearPartialDownload(for: file)
            progressTracker.update(identifier: file.path, downloadedBytes: 0)
            throw VoiceInkRefineDownloadError.invalidContentRange(file.path)
        }

        guard response.statusCode == 200 || response.statusCode == 206 else {
            throw VoiceInkRefineDownloadError.unexpectedStatusCode(
                response.statusCode,
                file.path
            )
        }

        do {
            try Self.validateDownloadedFile(at: partialURL, file: file)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            clearPartialDownload(for: file)
            progressTracker.update(identifier: file.path, downloadedBytes: 0)
            throw error
        }

        try installDownloadedFile(at: partialURL, file: file)
    }

    private func streamDownload(
        request: URLRequest,
        to destination: URL,
        file: ModelFile,
        resumeOffset: Int64,
        onProgress: @escaping @Sendable (Int64) -> Void,
        onResponse: @escaping @Sendable (HTTPURLResponse) -> Void
    ) async throws -> HTTPURLResponse {
        let delegate = StreamingDownloadDelegate(
            destination: destination,
            file: file,
            resumeOffset: resumeOffset,
            rangeHeader: request.value(forHTTPHeaderField: "Range"),
            ifRangeHeader: request.value(forHTTPHeaderField: "If-Range"),
            onProgress: onProgress,
            onResponse: onResponse
        )

        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.waitsForConnectivity = true

        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.prakashjoshipax.voiceink.refine-download"
        delegateQueue.qualityOfService = .utility
        delegateQueue.maxConcurrentOperationCount = 1

        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: delegateQueue
        )
        defer {
            session.invalidateAndCancel()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                delegate.attach(continuation: continuation, task: task)
                if Task.isCancelled {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    private func installDownloadedFile(at partialURL: URL, file: ModelFile) throws {
        let finalURL = snapshotDirectory.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(
            at: finalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }

        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        try? FileManager.default.removeItem(at: validatorURL(for: file))
        progressTracker.update(identifier: file.path, downloadedBytes: file.size)
    }

    private func validateSnapshot() throws {
        for file in files {
            try Self.validateDownloadedFile(
                at: snapshotDirectory.appendingPathComponent(file.path),
                file: file
            )
        }

        guard let record = Self.verificationRecord(
            at: snapshotDirectory,
            files: files
        ) else {
            throw VoiceInkRefineDownloadError.invalidResponse(
                Self.verificationRecordFilename
            )
        }
        try Self.persistVerificationRecord(record, at: snapshotDirectory)
    }

    private func downloadURL(for file: ModelFile) -> URL? {
        let encodedPath =
            file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? file.path
        return URL(
            string: "https://huggingface.co/\(repositoryID)/resolve/\(revision)/\(encodedPath)"
        )
    }

    private func partialURL(for file: ModelFile) -> URL {
        partialsDirectory
            .appendingPathComponent(file.path)
            .appendingPathExtension("partial")
    }

    private func validatorURL(for file: ModelFile) -> URL {
        partialURL(for: file).appendingPathExtension("etag")
    }

    private func clearPartialDownload(for file: ModelFile) {
        try? FileManager.default.removeItem(at: partialURL(for: file))
        try? FileManager.default.removeItem(at: validatorURL(for: file))
    }

    private func persistResumeValidator(
        from response: HTTPURLResponse,
        to validatorURL: URL
    ) {
        let validator: String?
        if let etag = response.value(forHTTPHeaderField: "ETag"),
           !etag.hasPrefix("W/")
        {
            validator = etag
        } else {
            validator = response.value(forHTTPHeaderField: "Last-Modified")
        }

        if let validator {
            try? validator.write(
                to: validatorURL,
                atomically: true,
                encoding: .utf8
            )
        } else {
            try? FileManager.default.removeItem(at: validatorURL)
        }
    }

    static func validateDownloadedFile(
        at url: URL,
        file: ModelFile
    ) throws {
        let actualSize = fileSize(at: url) ?? 0
        guard actualSize == file.size else {
            throw VoiceInkRefineDownloadError.invalidFileSize(
                file.path,
                expected: file.size,
                actual: actualSize
            )
        }

        guard let expectedSHA256 = file.sha256 else {
            return
        }

        let actualSHA256 = try sha256(of: url)
        guard actualSHA256 == expectedSHA256 else {
            throw VoiceInkRefineDownloadError.invalidChecksum(file.path)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024),
              !data.isEmpty
        {
            try Task.checkCancellation()
            hasher.update(data: data)
        }

        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func verificationRecord(
        at snapshotDirectory: URL,
        files: [ModelFile]
    ) -> SnapshotVerificationRecord? {
        let fileManager = FileManager.default
        var records: [SnapshotFileVerificationRecord] = []
        records.reserveCapacity(files.count)

        for file in files {
            let fileURL = snapshotDirectory.appendingPathComponent(file.path)
            guard
                let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                let size = (attributes[.size] as? NSNumber)?.int64Value,
                size == file.size,
                let modificationDate = attributes[.modificationDate] as? Date
            else {
                return nil
            }

            records.append(
                SnapshotFileVerificationRecord(
                    path: file.path,
                    size: size,
                    expectedSHA256: file.sha256,
                    modificationTime: modificationDate.timeIntervalSinceReferenceDate
                )
            )
        }

        return SnapshotVerificationRecord(
            version: verificationRecordVersion,
            files: records
        )
    }

    private static func storedVerificationRecord(
        at snapshotDirectory: URL
    ) -> SnapshotVerificationRecord? {
        let url = snapshotDirectory.appendingPathComponent(verificationRecordFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SnapshotVerificationRecord.self, from: data)
    }

    private static func persistVerificationRecord(
        _ record: SnapshotVerificationRecord,
        at snapshotDirectory: URL
    ) throws {
        let data = try JSONEncoder().encode(record)
        try data.write(
            to: snapshotDirectory.appendingPathComponent(verificationRecordFilename),
            options: .atomic
        )
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return nil
        }

        return size.int64Value
    }

    private static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [
                .timedOut,
                .cannotFindHost,
                .cannotConnectToHost,
                .networkConnectionLost,
                .dnsLookupFailed,
                .notConnectedToInternet,
                .resourceUnavailable,
                .secureConnectionFailed,
            ].contains(urlError.code)
        }

        switch error {
        case VoiceInkRefineDownloadError.invalidContentRange,
             VoiceInkRefineDownloadError.invalidFileSize,
             VoiceInkRefineDownloadError.invalidChecksum:
            return true
        case let VoiceInkRefineDownloadError.unexpectedStatusCode(statusCode, _):
            return statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
        default:
            return false
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorCancelled
    }

    private final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private struct State {
            var continuation: CheckedContinuation<HTTPURLResponse, Error>?
            var task: URLSessionDataTask?
            var handle: FileHandle?
            var writeError: Error?
            var responseError: Error?
            var bytesWritten: Int64 = 0
            var finished = false
        }

        private let destination: URL
        private let file: ModelFile
        private let resumeOffset: Int64
        private let rangeHeader: String?
        private let ifRangeHeader: String?
        private let onProgress: @Sendable (Int64) -> Void
        private let onResponse: @Sendable (HTTPURLResponse) -> Void
        private let lock = NSLock()
        private var state = State()

        init(
            destination: URL,
            file: ModelFile,
            resumeOffset: Int64,
            rangeHeader: String?,
            ifRangeHeader: String?,
            onProgress: @escaping @Sendable (Int64) -> Void,
            onResponse: @escaping @Sendable (HTTPURLResponse) -> Void
        ) {
            self.destination = destination
            self.file = file
            self.resumeOffset = resumeOffset
            self.rangeHeader = rangeHeader
            self.ifRangeHeader = ifRangeHeader
            self.onProgress = onProgress
            self.onResponse = onResponse
        }

        func attach(
            continuation: CheckedContinuation<HTTPURLResponse, Error>,
            task: URLSessionDataTask
        ) {
            withState {
                $0.continuation = continuation
                $0.task = task
            }
        }

        func cancel() {
            let task = withState { $0.task }
            task?.cancel()
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            var redirectedRequest = request
            redirectedRequest.setValue("VoiceInk", forHTTPHeaderField: "User-Agent")
            if let rangeHeader {
                redirectedRequest.setValue(rangeHeader, forHTTPHeaderField: "Range")
            }
            if let ifRangeHeader {
                redirectedRequest.setValue(ifRangeHeader, forHTTPHeaderField: "If-Range")
            }
            completionHandler(redirectedRequest)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let httpResponse = response as? HTTPURLResponse else {
                withState {
                    $0.responseError = VoiceInkRefineDownloadError.invalidResponse(
                        file.path
                    )
                }
                completionHandler(.cancel)
                return
            }

            do {
                try validateResponse(httpResponse)

                guard httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
                    completionHandler(.allow)
                    return
                }

                onResponse(httpResponse)

                if !FileManager.default.fileExists(atPath: destination.path) {
                    FileManager.default.createFile(atPath: destination.path, contents: nil)
                }

                let handle = try FileHandle(forWritingTo: destination)
                let isResuming = httpResponse.statusCode == 206
                if isResuming {
                    try handle.seekToEnd()
                } else {
                    try handle.truncate(atOffset: 0)
                }

                let baseBytes = isResuming ? resumeOffset : 0
                withState {
                    $0.handle = handle
                    $0.bytesWritten = baseBytes
                }
                onProgress(baseBytes)
                completionHandler(.allow)
            } catch {
                withState {
                    $0.responseError = error
                }
                completionHandler(.cancel)
            }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            let downloadedBytes: Int64? = withState {
                guard let handle = $0.handle,
                      $0.writeError == nil
                else {
                    return nil
                }

                do {
                    try handle.write(contentsOf: data)
                    $0.bytesWritten += Int64(data.count)
                    return $0.bytesWritten
                } catch {
                    $0.writeError = error
                    return nil
                }
            }

            if let downloadedBytes {
                onProgress(downloadedBytes)
            } else if withState({ $0.writeError }) != nil {
                cancel()
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            let response = task.response as? HTTPURLResponse
            let completion: (() -> Void)? = withState {
                guard !$0.finished,
                      let continuation = $0.continuation
                else {
                    return nil
                }

                $0.finished = true
                $0.continuation = nil
                $0.task = nil
                try? $0.handle?.close()
                $0.handle = nil

                let responseError = $0.responseError
                let writeError = $0.writeError
                return {
                    if let responseError {
                        continuation.resume(throwing: responseError)
                    } else if let writeError {
                        continuation.resume(throwing: writeError)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else if let response {
                        continuation.resume(returning: response)
                    } else {
                        continuation.resume(
                            throwing: VoiceInkRefineDownloadError.invalidResponse(
                                self.file.path
                            )
                        )
                    }
                }
            }

            completion?()
        }

        private func validateResponse(_ response: HTTPURLResponse) throws {
            guard response.statusCode == 206 else {
                return
            }

            guard resumeOffset > 0,
                  let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
                  let range = Self.parseContentRange(contentRange),
                  range.start == resumeOffset,
                  range.end < file.size,
                  range.total == file.size
            else {
                throw VoiceInkRefineDownloadError.invalidContentRange(file.path)
            }
        }

        private static func parseContentRange(
            _ value: String
        ) -> (start: Int64, end: Int64, total: Int64)? {
            let normalized = value.lowercased()
            guard normalized.hasPrefix("bytes ") else {
                return nil
            }

            let components = normalized.dropFirst("bytes ".count).split(separator: "/")
            guard components.count == 2,
                  let total = Int64(components[1])
            else {
                return nil
            }

            let rangeComponents = components[0].split(separator: "-")
            guard rangeComponents.count == 2,
                  let start = Int64(rangeComponents[0]),
                  let end = Int64(rangeComponents[1])
            else {
                return nil
            }

            return (start, end, total)
        }

        private func withState<T>(_ operation: (inout State) -> T) -> T {
            lock.lock()
            defer {
                lock.unlock()
            }
            return operation(&state)
        }
    }
}

private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let totalBytes: Int64
    private var bytesByFile: [String: Int64] = [:]
    private var isFinalizing = false

    init(totalBytes: Int64) {
        self.totalBytes = totalBytes
    }

    func update(identifier: String, downloadedBytes: Int64) {
        lock.lock()
        bytesByFile[identifier] = max(0, downloadedBytes)
        lock.unlock()
    }

    func beginFinalizing() {
        lock.lock()
        isFinalizing = true
        lock.unlock()
    }

    func snapshot() -> VoiceInkRefineDownloadProgress {
        lock.lock()
        let downloadedBytes = min(
            totalBytes,
            bytesByFile.values.reduce(Int64(0), +)
        )
        let snapshot = VoiceInkRefineDownloadProgress(
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes,
            isFinalizing: isFinalizing
        )
        lock.unlock()
        return snapshot
    }
}
