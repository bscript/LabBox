import Foundation

/// Host end of the control port. Events are delivered on the main queue.
public final class GuestChannel {
    private let toGuest: FileHandle
    private let fromGuest: FileHandle
    private var decoder = FrameDecoder()
    private var broken = false

    public var onEvent: ((GuestEvent) -> Void)?
    /// Called once if the guest sends something that is not valid protocol.
    public var onBroken: ((String) -> Void)?

    init(toGuest: FileHandle, fromGuest: FileHandle) {
        self.toGuest = toGuest
        self.fromGuest = fromGuest
    }

    func start() {
        fromGuest.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.consume(bytes) }
        }
    }

    public func send(_ request: GuestRequest) throws {
        let body = try JSONEncoder().encode(request)
        try toGuest.write(contentsOf: Frame.encode(body))
    }

    private func consume(_ bytes: Data) {
        guard !broken else { return }
        do {
            for frame in try decoder.feed(bytes) {
                onEvent?(try JSONDecoder().decode(GuestEvent.self, from: frame))
            }
        } catch {
            broken = true
            fromGuest.readabilityHandler = nil
            onBroken?("\(error)")
        }
    }
}
