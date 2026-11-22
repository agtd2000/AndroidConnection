import AppKit
import SwiftUI
import CoreVideo

final class MirrorPlayerView: NSView {
    var onTap: ((CGPoint) -> Void)?
    var onSwipe: ((CGPoint, CGPoint) -> Void)?
    var onKeyDown: ((NSEvent) -> Void)?
    var onScroll: ((CGFloat) -> Void)?

    private(set) var videoSize: CGSize = .zero
    private var pressPoint: CGPoint?
    private var scrollAccumulator: CGFloat = 0

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

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

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
