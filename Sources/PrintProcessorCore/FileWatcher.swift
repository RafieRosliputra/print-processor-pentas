import Foundation
import Darwin

/// Watches a single file for write/delete/rename events (used to detect when a
/// PSD or photo is saved/closed) and calls the handler after a debounce window.
public final class FileWatcher {
    public typealias Handler = (String) -> Void

    private let path: String
    private let debounce: TimeInterval
    private let queue: DispatchQueue
    private let handler: Handler

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounceWork: DispatchWorkItem?

    public init(path: String, debounce: TimeInterval = 2.0,
                queue: DispatchQueue = DispatchQueue(label: "com.johorstudio.printprocessor.filewatcher"),
                handler: @escaping Handler) {
        self.path = path
        self.debounce = debounce
        self.queue = queue
        self.handler = handler
    }

    public var isRunning: Bool { source != nil }

    public func start() {
        stop()
        let flags = O_EVTONLY
        fd = open(path, flags)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.scheduleFire()
        }
        src.setCancelHandler { [weak self] in
            if let self = self, self.fd >= 0 {
                close(self.fd)
                self.fd = -1
            }
        }
        source = src
        src.resume()
    }

    public func stop() {
        debounceWork?.cancel()
        debounceWork = nil
        source?.cancel()
        source = nil
    }

    deinit {
        stop()
    }

    private func scheduleFire() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.debounceWork = nil
            self.handler(self.path)
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
