import CoreFoundation
import IOKit.ps

final class PowerSourceObserver: @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private var source: CFRunLoopSource?

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanagedSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let observer = Unmanaged<PowerSourceObserver>
                .fromOpaque(context)
                .takeUnretainedValue()
            observer.onChange()
        }, context) else {
            return
        }

        let source = unmanagedSource.takeRetainedValue()
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    deinit {
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        CFRunLoopSourceInvalidate(source)
    }
}
