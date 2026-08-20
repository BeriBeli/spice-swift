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
    package static func cursorLayer(
        for pointerMode: SpicePointerMode,
        isPointerCaptured: Bool = true
    ) -> SpiceCursorLayer {
        switch pointerMode {
        case .absolute: .native
        case .relative: isPointerCaptured ? .overlay : .native
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
        destinationSize: CGSize,
        isPointerCaptured: Bool = true
    ) -> SpiceSystemCursorDescriptor {
        guard pointerMode == .absolute else {
            return isPointerCaptured ? .transparent : .arrow
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
package final class SpicePointerCaptureController {
    private let disconnectCursor: () -> Bool
    private let reconnectCursor: () -> Void
    private let currentCursorLocation: () -> CGPoint?
    private let warpCursor: (CGPoint) -> Void
    private let hideCursor: () -> Void
    private let unhideCursor: () -> Void
    private var restoreLocation: CGPoint?

    package private(set) var isCaptured = false

    package init(
        disconnectCursor: @escaping () -> Bool,
        reconnectCursor: @escaping () -> Void,
        currentCursorLocation: @escaping () -> CGPoint?,
        warpCursor: @escaping (CGPoint) -> Void,
        hideCursor: @escaping () -> Void,
        unhideCursor: @escaping () -> Void
    ) {
        self.disconnectCursor = disconnectCursor
        self.reconnectCursor = reconnectCursor
        self.currentCursorLocation = currentCursorLocation
        self.warpCursor = warpCursor
        self.hideCursor = hideCursor
        self.unhideCursor = unhideCursor
    }

    package static func system() -> SpicePointerCaptureController {
        SpicePointerCaptureController(
            disconnectCursor: {
                CGAssociateMouseAndMouseCursorPosition(0) == .success
            },
            reconnectCursor: {
                _ = CGAssociateMouseAndMouseCursorPosition(1)
            },
            currentCursorLocation: {
                CGEvent(source: nil)?.location
            },
            warpCursor: { location in
                _ = CGWarpMouseCursorPosition(location)
            },
            hideCursor: {
                NSCursor.hide()
            },
            unhideCursor: {
                NSCursor.unhide()
            }
        )
    }

    @discardableResult
    package func capture() -> Bool {
        guard !isCaptured else { return true }
        let location = currentCursorLocation()
        guard disconnectCursor() else { return false }
        restoreLocation = location
        hideCursor()
        isCaptured = true
        return true
    }

    package func release() {
        guard isCaptured else { return }
        if let restoreLocation {
            warpCursor(restoreLocation)
        }
        reconnectCursor()
        unhideCursor()
        restoreLocation = nil
        isCaptured = false
    }
}

/// A narrow SwiftUI-to-AppKit bridge for framebuffer drawing and physical
/// input capture. SwiftUI owns the frame and cursor values; the wrapped NSView
/// owns only transient responder and tracking state.
public struct SpiceDesktopView: NSViewRepresentable {
    public var frame: SpiceFrame?
    public var cursor: SpiceCursorState?
    public var pointerMode: SpicePointerMode
    public var presentationDiagnostics: SpicePresentationDiagnostics?
    public var onFrameUpdate: (@MainActor @Sendable () -> Void)?
    public var onInput: @MainActor @Sendable (SpiceClientInput) -> Void

    public init(
        frame: SpiceFrame?,
        cursor: SpiceCursorState? = nil,
        pointerMode: SpicePointerMode = .absolute,
        presentationDiagnostics: SpicePresentationDiagnostics? = nil,
        onFrameUpdate: (@MainActor @Sendable () -> Void)? = nil,
        onInput: @escaping @MainActor @Sendable (SpiceClientInput) -> Void
    ) {
        self.frame = frame
        self.cursor = cursor
        self.pointerMode = pointerMode
        self.presentationDiagnostics = presentationDiagnostics
        self.onFrameUpdate = onFrameUpdate
        self.onInput = onInput
    }

    public func makeNSView(context: Context) -> NSView {
        SpiceFramebufferView(
            frame: frame,
            cursorState: cursor,
            pointerMode: pointerMode,
            presentationDiagnostics: presentationDiagnostics,
            onInput: onInput
        )
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let framebufferView = nsView as? SpiceFramebufferView else {
            return
        }
        let didUpdateFrame = framebufferView.update(
            frame: frame,
            cursorState: cursor,
            pointerMode: pointerMode,
            presentationDiagnostics: presentationDiagnostics,
            onInput: onInput
        )
        if didUpdateFrame {
            onFrameUpdate?()
        }
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: Void) {
        (nsView as? SpiceFramebufferView)?.prepareForDismantle()
    }
}

@MainActor
private final class SpiceFramebufferView: NSView {
    private var desktopFrame: SpiceFrame?
    private var cursorState: SpiceCursorState?
    private var pointerMode: SpicePointerMode
    private var presentationDiagnostics: SpicePresentationDiagnostics?
    private var windowObservers: [NSObjectProtocol] = []
    private var onInput: @MainActor @Sendable (SpiceClientInput) -> Void
    private var trackingArea: NSTrackingArea?
    private var pressedScanCodes: Set<UInt32> = []
    private let metalView: SpiceMetalFrameView?
    private let cursorOverlay = SpiceCursorOverlayView()
    private var isUsingMetal = false
    private var systemCursorDescriptor: SpiceSystemCursorDescriptor?
    private var systemCursor: NSCursor = .arrow
    private let pointerCapture = SpicePointerCaptureController.system()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    fileprivate init(
        frame: SpiceFrame?,
        cursorState: SpiceCursorState?,
        pointerMode: SpicePointerMode,
        presentationDiagnostics: SpicePresentationDiagnostics?,
        onInput: @escaping @MainActor @Sendable (SpiceClientInput) -> Void
    ) {
        desktopFrame = frame
        self.cursorState = cursorState
        self.pointerMode = pointerMode
        self.presentationDiagnostics = presentationDiagnostics
        self.onInput = onInput
        self.metalView = SpiceMetalFrameView(
            presentationDiagnostics: presentationDiagnostics
        )
        super.init(frame: .zero)
        if let metalView {
            addSubview(metalView)
        }
        addSubview(cursorOverlay)
        updatePresentedFrame(frame)
        updateCursorPresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @discardableResult
    fileprivate func update(
        frame: SpiceFrame?,
        cursorState: SpiceCursorState?,
        pointerMode: SpicePointerMode,
        presentationDiagnostics: SpicePresentationDiagnostics?,
        onInput: @escaping @MainActor @Sendable (SpiceClientInput) -> Void
    ) -> Bool {
        let frameChanged = !Self.framesSharePresentationStorage(desktopFrame, frame)
        self.presentationDiagnostics = presentationDiagnostics
        metalView?.setPresentationDiagnostics(presentationDiagnostics)
        self.cursorState = cursorState
        self.pointerMode = pointerMode
        self.onInput = onInput
        if pointerMode == .absolute {
            releasePointerCapture()
        }
        if frameChanged {
            updatePresentedFrame(frame)
        } else {
            desktopFrame = frame
        }
        updateCursorPresentation()
        needsLayout = true
        needsDisplay = true
        return frameChanged
    }

    private func updatePresentedFrame(_ frame: SpiceFrame?) {
        desktopFrame = frame
        if let metalView {
            isUsingMetal = metalView.present(frame)
            return
        }
        isUsingMetal = false
        if frame != nil {
            presentationDiagnostics?.recordCPUFallback(.metalUnavailable)
        }
    }

    private static func framesSharePresentationStorage(
        _ lhs: SpiceFrame?,
        _ rhs: SpiceFrame?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            lhs.sharesPresentationStorage(with: rhs)
        default:
            false
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObservers()
        guard let window else {
            releasePointerCapture()
            return
        }
        window.acceptsMouseMovedEvents = true
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
        ]
        windowObservers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.releasePointerCapture()
                }
            }
        }
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        for observer in windowObservers {
            center.removeObserver(observer)
        }
        windowObservers.removeAll()
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
        guard let scanCode = MacXTScanCode.map[event.keyCode] else {
            super.keyDown(with: event)
            return
        }
        pressedScanCodes.insert(scanCode)
        onInput(.keyDown(scanCode: scanCode))
    }

    override func keyUp(with event: NSEvent) {
        guard let scanCode = MacXTScanCode.map[event.keyCode] else {
            super.keyUp(with: event)
            return
        }
        pressedScanCodes.remove(scanCode)
        onInput(.keyUp(scanCode: scanCode))
    }

    override func flagsChanged(with event: NSEvent) {
        guard let scanCode = MacXTScanCode.map[event.keyCode] else {
            super.flagsChanged(with: event)
            return
        }
        if pressedScanCodes.insert(scanCode).inserted {
            onInput(.keyDown(scanCode: scanCode))
        } else {
            pressedScanCodes.remove(scanCode)
            onInput(.keyUp(scanCode: scanCode))
        }
    }

    override func resignFirstResponder() -> Bool {
        for scanCode in pressedScanCodes {
            onInput(.keyUp(scanCode: scanCode))
        }
        pressedScanCodes.removeAll(keepingCapacity: true)
        releasePointerCapture()
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        capturePointerIfNeeded()
        onInput(.mousePress(.left))
    }

    override func mouseUp(with event: NSEvent) {
        onInput(.mouseRelease(.left))
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        capturePointerIfNeeded()
        onInput(.mousePress(.right))
    }

    override func rightMouseUp(with event: NSEvent) {
        onInput(.mouseRelease(.right))
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        capturePointerIfNeeded()
        onInput(.mousePress(mouseButton(number: event.buttonNumber)))
    }

    override func otherMouseUp(with event: NSEvent) {
        onInput(.mouseRelease(mouseButton(number: event.buttonNumber)))
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
        onInput(.mousePress(button))
        onInput(.mouseRelease(button))
    }

    private func sendMotion(_ event: NSEvent) {
        switch pointerMode {
        case .relative:
            guard pointerCapture.isCaptured else { return }
            let dx = clampedInt32(event.deltaX.rounded())
            let dy = clampedInt32(event.deltaY.rounded())
            guard dx != 0 || dy != 0 else { return }
            onInput(.mouseMotion(dx: dx, dy: dy))
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
            onInput(.mousePosition(x: UInt32(x), y: UInt32(y), displayID: 0))
        }
    }

    private func capturePointerIfNeeded() {
        guard pointerMode == .relative, window?.isKeyWindow == true else { return }
        if pointerCapture.capture() {
            updateCursorPresentation()
        }
    }

    fileprivate func releasePointerCapture() {
        pointerCapture.release()
        updateCursorPresentation()
    }

    @objc func releaseSpicePointerCapture(_ sender: Any?) {
        releasePointerCapture()
    }

    fileprivate func prepareForDismantle() {
        releasePointerCapture()
        removeWindowObservers()
    }

    private func contentRectangle(frameWidth: Int, frameHeight: Int) -> NSRect {
        SpiceFrameDrawing.contentRectangle(
            in: bounds,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )
    }

    private func updateCursorPresentation() {
        let usesOverlay = SpiceDesktopPresentationPolicy.cursorLayer(
            for: pointerMode,
            isPointerCaptured: pointerCapture.isCaptured
        ) == .overlay
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
            destinationSize: destinationSize,
            isPointerCaptured: pointerCapture.isCaptured
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

package enum MacXTScanCode {
    // macOS virtual key code to PC XT set-1 scan code. Extended E0 codes use
    // bit 8, matching spice-gtk's public scancode convention.
    static let map: [UInt16: UInt32] = [
        0: 0x1e, 1: 0x1f, 2: 0x20, 3: 0x21, 4: 0x23, 5: 0x22,
        6: 0x2c, 7: 0x2d, 8: 0x2e, 9: 0x2f, 11: 0x30, 12: 0x10,
        13: 0x11, 14: 0x12, 15: 0x13, 16: 0x15, 17: 0x14, 18: 0x02,
        19: 0x03, 20: 0x04, 21: 0x05, 22: 0x07, 23: 0x06, 24: 0x0d,
        25: 0x0a, 26: 0x08, 27: 0x0c, 28: 0x09, 29: 0x0b, 30: 0x1b,
        31: 0x18, 32: 0x16, 33: 0x1a, 34: 0x17, 35: 0x19, 36: 0x1c,
        37: 0x26, 38: 0x24, 39: 0x28, 40: 0x25, 41: 0x27, 42: 0x2b,
        43: 0x33, 44: 0x35, 45: 0x31, 46: 0x32, 47: 0x34, 48: 0x0f,
        49: 0x39, 50: 0x29, 51: 0x0e, 53: 0x01, 54: 0x15c, 55: 0x15b,
        56: 0x2a, 57: 0x3a, 58: 0x38, 59: 0x1d, 60: 0x36, 61: 0x138,
        62: 0x11d, 65: 0x53, 67: 0x37, 69: 0x4e, 71: 0x45, 75: 0x135,
        76: 0x11c, 78: 0x4a, 81: 0x59, 82: 0x52, 83: 0x4f, 84: 0x50,
        85: 0x51, 86: 0x4b, 87: 0x4c, 88: 0x4d, 89: 0x47, 91: 0x48,
        92: 0x49, 96: 0x3f, 97: 0x40, 98: 0x41, 99: 0x3d, 100: 0x42,
        101: 0x43, 103: 0x57, 105: 0x64, 106: 0x67, 107: 0x65,
        109: 0x44, 111: 0x58, 113: 0x66, 114: 0x152, 115: 0x147,
        116: 0x149, 117: 0x153, 118: 0x3e, 119: 0x14f, 120: 0x3c,
        121: 0x151, 122: 0x3b, 123: 0x14b, 124: 0x14d, 125: 0x150,
        126: 0x148,
    ]
}
