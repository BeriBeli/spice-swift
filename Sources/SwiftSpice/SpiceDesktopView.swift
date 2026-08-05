import AppKit
import CoreGraphics
import MetalKit
import SwiftUI

public enum SpicePointerMode: Sendable, Equatable {
    case relative
    case absolute

    public init(spiceMouseMode: UInt32) {
        self = spiceMouseMode == 2 ? .absolute : .relative
    }
}

package enum SpiceCursorLayer: Sendable, Equatable {
    case native
    case overlay
}

package enum SpiceSystemCursorDescriptor: Equatable {
    case arrow
    case transparent
    case image(cursor: SpiceCursorImage, scaleX: CGFloat, scaleY: CGFloat)
}

package enum SpiceDesktopPresentationPolicy {
    package static func cursorLayer(for pointerMode: SpicePointerMode) -> SpiceCursorLayer {
        switch pointerMode {
        case .absolute: .native
        case .relative: .overlay
        }
    }

    package static func drawableSize(
        for viewSize: CGSize,
        backingScaleFactor: CGFloat
    ) -> CGSize {
        guard viewSize.width.isFinite,
              viewSize.height.isFinite,
              backingScaleFactor.isFinite,
              viewSize.width > 0,
              viewSize.height > 0,
              backingScaleFactor > 0
        else {
            return .zero
        }
        return CGSize(
            width: (viewSize.width * backingScaleFactor).rounded(),
            height: (viewSize.height * backingScaleFactor).rounded()
        )
    }

    package static func systemCursorDescriptor(
        for pointerMode: SpicePointerMode,
        cursorState: SpiceCursorState?,
        frameSize: CGSize?,
        destinationSize: CGSize
    ) -> SpiceSystemCursorDescriptor {
        guard pointerMode == .absolute else {
            return .transparent
        }
        guard let cursorState else {
            return .arrow
        }
        guard cursorState.isVisible else {
            return .transparent
        }
        guard let frameSize,
              frameSize.width.isFinite,
              frameSize.height.isFinite,
              destinationSize.width.isFinite,
              destinationSize.height.isFinite,
              frameSize.width > 0,
              frameSize.height > 0,
              destinationSize.width > 0,
              destinationSize.height > 0,
              let cursor = cursorState.image,
              cursor.format == .alpha,
              cursor.width > 0,
              cursor.height > 0
        else {
            return .arrow
        }
        let (pixels, pixelOverflow) = cursor.width.multipliedReportingOverflow(by: cursor.height)
        let (byteCount, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow, cursor.data.count == byteCount else {
            return .arrow
        }
        return .image(
            cursor: cursor,
            scaleX: destinationSize.width / frameSize.width,
            scaleY: destinationSize.height / frameSize.height
        )
    }
}

@MainActor
final class SpiceDesktopFocusObserver: NSObject {
    private let onFocusLoss: @MainActor () -> Void

    init(onFocusLoss: @escaping @MainActor () -> Void) {
        self.onFocusLoss = onFocusLoss
    }

    func attach(to object: AnyObject?) {
        stop()
        guard let object else { return }
        let center = NotificationCenter.default
        for name in [
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
        ] {
            center.addObserver(
                self,
                selector: #selector(didLoseFocus(_:)),
                name: name,
                object: object
            )
        }
    }

    func stop() {
        let center = NotificationCenter.default
        for name in [
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
        ] {
            center.removeObserver(self, name: name, object: nil)
        }
    }

    @objc private func didLoseFocus(_ notification: Notification) {
        onFocusLoss()
    }
}

/// A narrow SwiftUI-to-AppKit bridge for framebuffer drawing and physical
/// input capture. SwiftUI owns the frame and cursor values; the wrapped NSView
/// owns only transient responder and tracking state.
public struct SpiceDesktopView: NSViewRepresentable {
    public var frame: SpiceFrame?
    public var cursor: SpiceCursorState?
    public var pointerMode: SpicePointerMode
    public var onInput: @MainActor @Sendable (SpiceClientInput) -> Void
    public var onInputEvent: @MainActor @Sendable (SpiceDesktopInputEvent) -> Void
    private var handlesWindowFocusLoss: Bool

    /// Compatibility initializer for applications that do not yet distinguish
    /// real human activity from synthetic focus cleanup.
    public init(
        frame: SpiceFrame?,
        cursor: SpiceCursorState? = nil,
        pointerMode: SpicePointerMode = .absolute,
        onInput: @escaping @MainActor @Sendable (SpiceClientInput) -> Void
    ) {
        self.frame = frame
        self.cursor = cursor
        self.pointerMode = pointerMode
        self.onInput = onInput
        self.onInputEvent = { onInput($0.input) }
        self.handlesWindowFocusLoss = false
    }

    /// Creates a desktop bridge that preserves human-activity semantics.
    /// Callers should process `.humanActivity` before forwarding its input so
    /// local takeover can revoke an agent writer first. `.focusCleanup` must
    /// only release human ownership.
    public static func sourceAware(
        frame: SpiceFrame?,
        cursor: SpiceCursorState? = nil,
        pointerMode: SpicePointerMode = .absolute,
        onInputEvent: @escaping @MainActor @Sendable (SpiceDesktopInputEvent) -> Void
    ) -> Self {
        Self(
            frame: frame,
            cursor: cursor,
            pointerMode: pointerMode,
            onInputEvent: onInputEvent
        )
    }

    private init(
        frame: SpiceFrame?,
        cursor: SpiceCursorState?,
        pointerMode: SpicePointerMode,
        onInputEvent: @escaping @MainActor @Sendable (SpiceDesktopInputEvent) -> Void
    ) {
        self.frame = frame
        self.cursor = cursor
        self.pointerMode = pointerMode
        self.onInput = { _ in }
        self.onInputEvent = onInputEvent
        self.handlesWindowFocusLoss = true
    }

    public func makeNSView(context: Context) -> NSView {
        SpiceFramebufferView(
            frame: frame,
            cursorState: cursor,
            pointerMode: pointerMode,
            handlesWindowFocusLoss: handlesWindowFocusLoss,
            onInputEvent: resolvedInputEventHandler
        )
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let framebufferView = nsView as? SpiceFramebufferView else {
            return
        }
        framebufferView.update(
            frame: frame,
            cursorState: cursor,
            pointerMode: pointerMode,
            handlesWindowFocusLoss: handlesWindowFocusLoss,
            onInputEvent: resolvedInputEventHandler
        )
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? SpiceFramebufferView)?.stopInputTracking()
    }

    private var resolvedInputEventHandler:
        @MainActor @Sendable (SpiceDesktopInputEvent) -> Void
    {
        if handlesWindowFocusLoss {
            return onInputEvent
        }
        let onInput = onInput
        return { onInput($0.input) }
    }
}

@MainActor
final class SpiceFramebufferView: NSView {
    private var desktopFrame: SpiceFrame?
    private var cursorState: SpiceCursorState?
    private var pointerMode: SpicePointerMode
    private var handlesWindowFocusLoss: Bool
    private var onInputEvent: @MainActor @Sendable (SpiceDesktopInputEvent) -> Void
    private var trackingArea: NSTrackingArea?
    private var humanInputState = SpiceHumanInputState()
    private lazy var focusObserver = SpiceDesktopFocusObserver { [weak self] in
        self?.releaseHumanInputForFocusLoss()
    }
    private let metalView: SpiceMetalFrameView?
    private let cursorOverlay = SpiceCursorOverlayView()
    private var isUsingMetal = false
    private var systemCursorDescriptor: SpiceSystemCursorDescriptor?
    private var systemCursor: NSCursor = .arrow

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(
        frame: SpiceFrame?,
        cursorState: SpiceCursorState?,
        pointerMode: SpicePointerMode,
        handlesWindowFocusLoss: Bool,
        onInputEvent: @escaping @MainActor @Sendable (SpiceDesktopInputEvent) -> Void
    ) {
        desktopFrame = frame
        self.cursorState = cursorState
        self.pointerMode = pointerMode
        self.handlesWindowFocusLoss = handlesWindowFocusLoss
        self.onInputEvent = onInputEvent
        self.metalView = SpiceMetalFrameView()
        super.init(frame: .zero)
        if let metalView {
            addSubview(metalView)
        }
        addSubview(cursorOverlay)
        isUsingMetal = metalView?.present(frame) ?? false
        updateCursorPresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    fileprivate func update(
        frame: SpiceFrame?,
        cursorState: SpiceCursorState?,
        pointerMode: SpicePointerMode,
        handlesWindowFocusLoss: Bool,
        onInputEvent: @escaping @MainActor @Sendable (SpiceDesktopInputEvent) -> Void
    ) {
        desktopFrame = frame
        self.cursorState = cursorState
        self.pointerMode = pointerMode
        let focusModeChanged = self.handlesWindowFocusLoss != handlesWindowFocusLoss
        self.handlesWindowFocusLoss = handlesWindowFocusLoss
        self.onInputEvent = onInputEvent
        if focusModeChanged {
            attachWindowObservers()
        }
        isUsingMetal = metalView?.present(frame) ?? false
        updateCursorPresentation()
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        cursorOverlay.frame = bounds
        guard let frame = desktopFrame else {
            metalView?.frame = .zero
            return
        }
        metalView?.frame = contentRectangle(
            frameWidth: frame.width,
            frameHeight: frame.height
        )
        updateCursorPresentation()
        cursorOverlay.needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: systemCursor)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachWindowObservers()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        guard !isUsingMetal,
              let frame = desktopFrame,
              let image = SpiceFrameDrawing.makeImage(frame)
        else {
            return
        }
        let destination = contentRectangle(frameWidth: frame.width, frameHeight: frame.height)
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: image, size: destination.size).draw(
            in: destination,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none]
        )
    }

    override func keyDown(with event: NSEvent) {
        guard let scanCode = SpiceKeyMap.scanCode(
            forMacVirtualKeyCode: event.keyCode
        ) else {
            super.keyDown(with: event)
            return
        }
        emit(humanInputState.keyDown(
            scanCode: scanCode,
            isRepeat: event.isARepeat
        ))
    }

    override func keyUp(with event: NSEvent) {
        guard let scanCode = SpiceKeyMap.scanCode(
            forMacVirtualKeyCode: event.keyCode
        ) else {
            super.keyUp(with: event)
            return
        }
        emit(humanInputState.keyUp(scanCode: scanCode))
    }

    override func flagsChanged(with event: NSEvent) {
        guard let scanCode = SpiceKeyMap.scanCode(
            forMacVirtualKeyCode: event.keyCode
        ) else {
            super.flagsChanged(with: event)
            return
        }
        emit(humanInputState.modifierChanged(scanCode: scanCode))
    }

    override func resignFirstResponder() -> Bool {
        releaseHumanInputForFocusLoss()
        return super.resignFirstResponder()
    }

    fileprivate func releaseHumanInputForFocusLoss() {
        for event in humanInputState.releaseForFocusLoss() {
            emit(event)
        }
    }

    fileprivate func stopInputTracking() {
        removeWindowObservers()
        guard handlesWindowFocusLoss else { return }
        releaseHumanInputForFocusLoss()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        emit(humanInputState.buttonDown(.left))
    }

    override func mouseUp(with event: NSEvent) {
        emit(humanInputState.buttonUp(.left))
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        emit(humanInputState.buttonDown(.right))
    }

    override func rightMouseUp(with event: NSEvent) {
        emit(humanInputState.buttonUp(.right))
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        emit(humanInputState.buttonDown(mouseButton(number: event.buttonNumber)))
    }

    override func otherMouseUp(with event: NSEvent) {
        emit(humanInputState.buttonUp(mouseButton(number: event.buttonNumber)))
    }

    override func mouseMoved(with event: NSEvent) { sendMotion(event) }
    override func mouseDragged(with event: NSEvent) { sendMotion(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMotion(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMotion(event) }

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else {
            return
        }
        let button: SpiceMouseButton = event.scrollingDeltaY > 0 ? .scrollUp : .scrollDown
        emitActivity(.mousePress(button))
        emitActivity(.mouseRelease(button))
    }

    private func sendMotion(_ event: NSEvent) {
        switch pointerMode {
        case .relative:
            emitActivity(.mouseMotion(
                dx: clampedInt32(event.deltaX.rounded()),
                dy: clampedInt32(event.deltaY.rounded())
            ))
        case .absolute:
            guard let frame = desktopFrame else {
                return
            }
            guard frame.width > 0, frame.height > 0 else {
                return
            }
            let point = convert(event.locationInWindow, from: nil)
            let destination = contentRectangle(frameWidth: frame.width, frameHeight: frame.height)
            guard destination.contains(point) else {
                return
            }
            let x = min(frame.width - 1, max(0, Int(
                ((point.x - destination.minX) / destination.width) * CGFloat(frame.width)
            )))
            let y = min(frame.height - 1, max(0, Int(
                ((point.y - destination.minY) / destination.height) * CGFloat(frame.height)
            )))
            emitActivity(.mousePosition(x: UInt32(x), y: UInt32(y), displayID: 0))
        }
    }

    private func emit(_ event: SpiceDesktopInputEvent?) {
        guard let event else { return }
        onInputEvent(event)
    }

    private func emitActivity(_ input: SpiceClientInput) {
        emit(SpiceDesktopInputEvent(input: input, origin: .humanActivity))
    }

    private func attachWindowObservers() {
        guard handlesWindowFocusLoss else {
            focusObserver.stop()
            return
        }
        focusObserver.attach(to: window)
    }

    private func removeWindowObservers() {
        focusObserver.stop()
    }

    private func contentRectangle(frameWidth: Int, frameHeight: Int) -> NSRect {
        SpiceFrameDrawing.contentRectangle(
            in: bounds,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )
    }

    private func updateCursorPresentation() {
        let usesOverlay = SpiceDesktopPresentationPolicy.cursorLayer(for: pointerMode) == .overlay
        cursorOverlay.isHidden = !usesOverlay
        cursorOverlay.update(
            frame: desktopFrame,
            cursorState: usesOverlay ? cursorState : nil
        )
        let destinationSize = desktopFrame.map {
            contentRectangle(frameWidth: $0.width, frameHeight: $0.height).size
        } ?? .zero
        let descriptor = SpiceDesktopPresentationPolicy.systemCursorDescriptor(
            for: pointerMode,
            cursorState: cursorState,
            frameSize: desktopFrame.map {
                CGSize(width: $0.width, height: $0.height)
            },
            destinationSize: destinationSize
        )
        guard descriptor != systemCursorDescriptor else {
            return
        }
        systemCursorDescriptor = descriptor
        systemCursor = SpiceFrameDrawing.makeSystemCursor(descriptor)
        window?.invalidateCursorRects(for: self)
    }

    private func clampedInt32(_ value: CGFloat) -> Int32 {
        guard value.isFinite else {
            return 0
        }
        let bounded = min(CGFloat(Int32.max), max(CGFloat(Int32.min), value))
        return Int32(bounded)
    }

    private func mouseButton(number: Int) -> SpiceMouseButton {
        switch number {
        case 2: .middle
        case 4: .extra
        default: .side
        }
    }
}

@MainActor
private final class SpiceCursorOverlayView: NSView {
    private var desktopFrame: SpiceFrame?
    private var cursorState: SpiceCursorState?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    fileprivate func update(frame: SpiceFrame?, cursorState: SpiceCursorState?) {
        desktopFrame = frame
        self.cursorState = cursorState
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let desktopFrame else {
            return
        }
        let destination = SpiceFrameDrawing.contentRectangle(
            in: bounds,
            frameWidth: desktopFrame.width,
            frameHeight: desktopFrame.height
        )
        SpiceFrameDrawing.drawCursor(
            cursorState,
            in: destination,
            frame: desktopFrame
        )
    }
}

@MainActor
private enum SpiceFrameDrawing {
    static let transparentCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: image, hotSpot: .zero)
    }()

    static func contentRectangle(
        in bounds: NSRect,
        frameWidth: Int,
        frameHeight: Int
    ) -> NSRect {
        guard frameWidth > 0, frameHeight > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let scale = min(
            bounds.width / CGFloat(frameWidth),
            bounds.height / CGFloat(frameHeight)
        )
        let size = NSSize(width: CGFloat(frameWidth) * scale, height: CGFloat(frameHeight) * scale)
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func makeImage(_ frame: SpiceFrame) -> CGImage? {
        let (minimumBytesPerRow, rowOverflow) = frame.width.multipliedReportingOverflow(by: 4)
        let (expectedBytes, sizeOverflow) = frame.bytesPerRow.multipliedReportingOverflow(
            by: frame.height
        )
        let pixels = frame.pixels
        guard frame.width > 0, frame.height > 0,
              !rowOverflow, !sizeOverflow,
              frame.bytesPerRow >= minimumBytesPerRow,
              pixels.count == expectedBytes,
              let provider = CGDataProvider(data: pixels as CFData)
        else {
            return nil
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
        ))
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    static func makeSystemCursor(_ descriptor: SpiceSystemCursorDescriptor) -> NSCursor {
        switch descriptor {
        case .arrow:
            return .arrow
        case .transparent:
            return transparentCursor
        case let .image(cursor, scaleX, scaleY):
            return makeSystemCursorImage(cursor, scaleX: scaleX, scaleY: scaleY)
        }
    }

    private static func makeSystemCursorImage(
        _ cursor: SpiceCursorImage,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> NSCursor {
        let cursorFrame = SpiceFrame(
            surfaceID: 0,
            width: cursor.width,
            height: cursor.height,
            bytesPerRow: cursor.width * 4,
            pixels: cursor.data
        )
        guard let image = makeImage(cursorFrame) else {
            return .arrow
        }
        let size = NSSize(
            width: CGFloat(cursor.width) * scaleX,
            height: CGFloat(cursor.height) * scaleY
        )
        guard size.width > 0, size.height > 0 else {
            return .arrow
        }
        return NSCursor(
            image: NSImage(cgImage: image, size: size),
            hotSpot: NSPoint(
                x: CGFloat(cursor.hotSpotX) * scaleX,
                y: CGFloat(cursor.hotSpotY) * scaleY
            )
        )
    }

    static func drawCursor(
        _ cursorState: SpiceCursorState?,
        in destination: NSRect,
        frame: SpiceFrame
    ) {
        guard let cursorState, cursorState.isVisible,
              let cursor = cursorState.image,
              cursor.format == .alpha,
              cursor.width > 0, cursor.height > 0
        else {
            return
        }
        let (pixels, pixelOverflow) = cursor.width.multipliedReportingOverflow(by: cursor.height)
        let (byteCount, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow, cursor.data.count == byteCount else {
            return
        }
        let cursorFrame = SpiceFrame(
            surfaceID: 0,
            width: cursor.width,
            height: cursor.height,
            bytesPerRow: cursor.width * 4,
            pixels: cursor.data
        )
        guard let image = makeImage(cursorFrame) else {
            return
        }
        let scaleX = destination.width / CGFloat(frame.width)
        let scaleY = destination.height / CGFloat(frame.height)
        let rectangle = NSRect(
            x: destination.minX + CGFloat(cursorState.x - cursor.hotSpotX) * scaleX,
            y: destination.minY + CGFloat(cursorState.y - cursor.hotSpotY) * scaleY,
            width: CGFloat(cursor.width) * scaleX,
            height: CGFloat(cursor.height) * scaleY
        )
        NSImage(cgImage: image, size: rectangle.size).draw(
            in: rectangle,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none]
        )
    }

}
