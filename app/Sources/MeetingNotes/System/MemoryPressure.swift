// System memory pressure level from a dispatch source (System).

import Foundation

/// Tracks the kernel's memory pressure notifications; `isCritical` pauses fast captions (the live rules).
final class MemoryPressureWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var critical = false
    private let source: DispatchSourceMemoryPressure

    init() {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.source.data
            self.lock.withLock { self.critical = event.contains(.critical) }
        }
        source.resume()
    }

    deinit { source.cancel() }

    var isCritical: Bool { lock.withLock { critical } }
}
