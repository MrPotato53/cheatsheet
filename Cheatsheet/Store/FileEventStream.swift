import CoreServices
import Foundation

/// A thin FSEvents wrapper: reports the paths that changed under the
/// watched paths (files or folders), batched by `latency`, on the main queue.
/// Event-driven, so it costs nothing while nothing changes.
@MainActor
final class FileEventStream {
    private var stream: FSEventStreamRef?
    private let box: Box

    /// Holds the handler for the C callback.
    private final class Box {
        let onEvents: @MainActor ([String]) -> Void
        init(_ onEvents: @escaping @MainActor ([String]) -> Void) { self.onEvents = onEvents }
    }

    init?(paths: [String], latency: TimeInterval = 0.3, onEvents: @escaping @MainActor ([String]) -> Void) {
        guard !paths.isEmpty else { return nil }
        box = Box(onEvents)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            let paths = Array(array.prefix(count))
            // Delivered on the main queue (see FSEventStreamSetDispatchQueue).
            MainActor.assumeIsolated { box.onEvents(paths) }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    isolated deinit {
        stop()
    }
}
