import Foundation

/// 使用下载任务的原生代理报告进度，并把结果桥接为 async/await。
nonisolated final class UpdateDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var result: Result<(URL, URLResponse), Error>?
    private var cancelled = false

    init(report: @escaping @Sendable (Int64, Int64) -> Void) {
        self.report = report
    }

    func download(from url: URL) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.default
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 300
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: url)
                let alreadyCancelled = lock.withLock {
                    if cancelled { return true }
                    self.continuation = continuation
                    self.session = session
                    self.task = task
                    return false
                }
                if alreadyCancelled {
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            let task = self.lock.withLock {
                self.cancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        report(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // 代理回调结束后系统会删除原临时文件，先转移到自己的临时路径。
        let result: Result<(URL, URLResponse), Error>
        do {
            guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("ScenaDownload-\(UUID().uuidString).zip")
            try FileManager.default.moveItem(at: location, to: file)
            result = .success((file, response))
        } catch {
            result = .failure(error)
        }
        lock.withLock { self.result = result }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, result) = lock.withLock {
            let continuation = self.continuation
            let result = self.result
            self.continuation = nil
            self.session = nil
            self.task = nil
            self.result = nil
            return (continuation, result)
        }
        session.finishTasksAndInvalidate()
        guard let continuation else { return }
        if let error {
            if case .success(let (file, _)) = result { try? FileManager.default.removeItem(at: file) }
            continuation.resume(throwing: error)
        } else {
            continuation.resume(with: result ?? .failure(URLError(.badServerResponse)))
        }
    }
}
