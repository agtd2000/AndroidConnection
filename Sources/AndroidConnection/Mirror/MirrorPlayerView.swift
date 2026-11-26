import AppKit
import SwiftUI
import CoreVideo

final class MirrorPlayerView: NSView {
    var onTap: ((CGPoint) -> Void)?
    var onSwipe: ((CGPoint, CGPoint) -> Void)?
    var onKeyDown: ((NSEvent) -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    var onRightClick: (() -> Void)?
    var onMiddleClick: (() -> Void)?

    private(set) var videoSize: CGSize = .zero
    private var pressPoint: CGPoint?
    private var scrollAccumulator: CGFloat = 0
    private var mouseMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Keep the video layer transparent outside the letterboxed image.
        // The surrounding SwiftUI stage owns the background, so portrait
        // streams no longer show black pillar bars.
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeMouseMonitor()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMouseMonitor()
        guard window != nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }

            if event.type == .rightMouseDown {
                self.window?.makeFirstResponder(self)
                self.onRightClick?()
                return nil
            }
            if event.type == .otherMouseDown, event.buttonNumber == 2 {
                self.window?.makeFirstResponder(self)
                self.onMiddleClick?()
                return nil
            }
            return event
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    func display(_ pixelBuffer: CVPixelBuffer, size: CGSize) {
        videoSize = size
        layer?.contents = pixelBuffer
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    func clear() {
        videoSize = .zero
        layer?.contents = nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = pressPoint else { return }
        let end = convert(event.locationInWindow, from: nil)
        pressPoint = nil

        let distance = hypot(end.x - start.x, end.y - start.y)
        if distance < 9 {
            if let point = normalized(start) {
                onTap?(point)
            }
        } else if let from = normalized(start), let to = normalized(end) {
            onSwipe?(from, to)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onRightClick?()
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        onMiddleClick?()
    }

    override func scrollWheel(with event: NSEvent) {
        scrollAccumulator += event.scrollingDeltaY
        if abs(scrollAccumulator) > 40 {
            onScroll?(scrollAccumulator > 0 ? 1 : -1)
            scrollAccumulator = 0
        }
    }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event)
    }

    private func normalized(_ point: CGPoint) -> CGPoint? {
        guard videoSize.width > 0, videoSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let drawnWidth = videoSize.width * scale
        let drawnHeight = videoSize.height * scale
        let originX = (bounds.width - drawnWidth) / 2
        let originY = (bounds.height - drawnHeight) / 2
        let x = (point.x - originX) / drawnWidth
        let y = (point.y - originY) / drawnHeight
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        return CGPoint(x: x, y: y)
    }
}

@MainActor
struct MirrorPlayerRepresentable: NSViewRepresentable {
    let session: MirrorSession

    func makeNSView(context: Context) -> MirrorPlayerView {
        let view = MirrorPlayerView()
        session.attach(view)
        return view
    }

    func updateNSView(_ nsView: MirrorPlayerView, context: Context) {
        session.attach(nsView)
    }
}
