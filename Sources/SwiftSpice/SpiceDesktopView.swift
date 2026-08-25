import AppKit
import CoreGraphics
import MetalKit
import QuartzCore
import SwiftUI
import Synchronization

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

package struct SpiceCursorImageCacheKey: Equatable {
    package let id: UInt64
    package let format: SpiceCursorImageFormat
    package let width: Int
    package let height: Int
    package let hotSpotX: Int
    package let hotSpotY: Int
    package let pixels: Data

    package init(_ cursor: SpiceCursorImage) {
        id = cursor.id
        format = cursor.format
        width = cursor.width
        height = cursor.height
        hotSpotX = cursor.hotSpotX
        hotSpotY = cursor.hotSpotY
        pixels = cursor.data
    }
}

package enum SpiceSystemCursorDescriptor: Equatable {
    case arrow
    case transparent
    case image(cursor: SpiceCursorImage, scaleX: CGFloat, scaleY: CGFloat)

    package static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.arrow, .arrow), (.transparent, .transparent):
            true
        case let (.image(lhsCursor, lhsScaleX, lhsScaleY),
                  .image(rhsCursor, rhsScaleX, rhsScaleY)):
            SpiceCursorImageCacheKey(lhsCursor)
                == SpiceCursorImageCacheKey(rhsCursor)
                && lhsScaleX == rhsScaleX
                && lhsScaleY == rhsScaleY
        default:
            false
        }
    }
}

package enum SpiceDesktopPresentationPolicy {
    package static func requiresFramebufferPresentation(
        selectedRevision: SpiceFrameRevision?,
        updateRevision: SpiceFrameRevision,
        requiresRedraw: Bool
    ) -> Bool {
        requiresRedraw || selectedRevision != updateRevision
    }

    /// Keeps cursor-only aggregate snapshots out of the framebuffer command
    /// path. The closure is invoked only for a new revision or an explicit
    /// geometry/backing-store redraw.
    package static func withFramebufferPresentationIfNeeded<Result>(
        selectedRevision: SpiceFrameRevision?,
        updateRevision: SpiceFrameRevision,
        requiresRedraw: Bool,
        _ presentation: () -> Result
    ) -> Result? {
        guard requiresFramebufferPresentation(
            selectedRevision: selectedRevision,
            updateRevision: updateRevision,
            requiresRedraw: requiresRedraw
        ) else {
            return nil
        }
        return presentation()
    }

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
        let (pixels, pixelOverflow) = cursor.width.multipliedReportingOverflow(
            by: cursor.height
        )
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

/// Bounded recovery for command buffers that fail after their revision was
/// accepted and acknowledged. Attempt identifiers make completion delivery
/// idempotent and keep late completions from an older revision or source from
/// reviving stale content.
package struct SpiceMetalFailureRecoveryPolicy {
    package struct Attempt: Sendable, Equatable {
        package let revision: SpiceFrameRevision
        fileprivate let identifier: UInt64
    }

    package enum Action: Sendable, Equatable {
        case none
        case requestLatest
        case useCPUFallback
    }

    private var nextAttemptIdentifier: UInt64 = 0
    private var trackedRevision: SpiceFrameRevision?
    private var activeAttemptIdentifiers: Set<UInt64> = []
    private var handledFailures = 0

    package mutating func beginAttempt(
        for revision: SpiceFrameRevision
    ) -> Attempt {
        if trackedRevision != revision {
            trackedRevision = revision
            activeAttemptIdentifiers.removeAll(keepingCapacity: true)
            handledFailures = 0
        }
        nextAttemptIdentifier &+= 1
        activeAttemptIdentifiers.insert(nextAttemptIdentifier)
        return Attempt(
            revision: revision,
            identifier: nextAttemptIdentifier
        )
    }

    package mutating func cancelAttempt(_ attempt: Attempt) {
        activeAttemptIdentifiers.remove(attempt.identifier)
    }

    package mutating func commandCompleted(
        _ attempt: Attempt,
        completion: SpiceMetalCommandCompletion,
        selectedRevision: SpiceFrameRevision?
    ) -> Action {
        guard trackedRevision == attempt.revision,
              selectedRevision == attempt.revision,
              activeAttemptIdentifiers.remove(attempt.identifier) != nil
        else {
            return .none
        }

        switch completion {
        case .succeeded:
            handledFailures = 0
            return .none
        case .failed:
            handledFailures += 1
            switch handledFailures {
            case 1:
                return .requestLatest
            case 2:
                // The revision will be redelivered once for CPU presentation.
                // Ignore any other already in-flight attempts for this frame.
                activeAttemptIdentifiers.removeAll(keepingCapacity: true)
                return .useCPUFallback
            default:
                return .none
            }
        }
    }

    package mutating func reset() {
        trackedRevision = nil
        activeAttemptIdentifiers.removeAll(keepingCapacity: true)
        handledFailures = 0
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

private struct SpiceDesktopFrameGeometry: Sendable, Equatable {
    let width: Int
    let height: Int
}

package final class SpiceDesktopReadyLatch: Sendable {
    private struct State: Sendable {
        var pending: SpiceDesktopSnapshot?
        var newestGeneration: UInt64?
        var newestDeliverySequence: UInt64 = 0
    }

    private let state = Mutex(State())

    /// Returns true only for the empty-to-ready transition.
    package func offer(_ snapshot: SpiceDesktopSnapshot) -> Bool {
        state.withLock { state in
            if Self.isOlder(
                snapshot,
                thanGeneration: state.newestGeneration,
                deliverySequence: state.newestDeliverySequence
            ) {
                return false
            }
            let wasEmpty = state.pending == nil
            state.pending = state.pending.map {
                SpiceDesktopSource.merging($0, snapshot)
            } ?? snapshot
            state.newestGeneration = state.pending?.generation
            state.newestDeliverySequence = state.pending?.deliverySequence ?? 0
            return wasEmpty
        }
    }

    package func take() -> SpiceDesktopSnapshot? {
        state.withLock { state in
            defer { state.pending = nil }
            return state.pending
        }
    }

    /// Keeps a failed presentation pending without replacing a newer update.
    package func restoreIfEmpty(_ snapshot: SpiceDesktopSnapshot) {
        state.withLock { state in
            guard state.pending == nil,
                  !Self.isOlder(
                      snapshot,
                      thanGeneration: state.newestGeneration,
                      deliverySequence: state.newestDeliverySequence
                  )
            else { return }
            state.pending = snapshot
            state.newestGeneration = snapshot.generation
            state.newestDeliverySequence = snapshot.deliverySequence
        }
    }

    package func discard() {
        state.withLock { $0.pending = nil }
    }

    package var isEmpty: Bool {
        state.withLock { $0.pending == nil }
    }

    private static func isOlder(
        _ snapshot: SpiceDesktopSnapshot,
        thanGeneration newestGeneration: UInt64?,
        deliverySequence newestDeliverySequence: UInt64
    ) -> Bool {
        guard let newestGeneration else { return false }
        if snapshot.generation != newestGeneration {
            return snapshot.generation < newestGeneration
        }
        return snapshot.deliverySequence < newestDeliverySequence
    }
}

/// A stable SwiftUI-to-AppKit boundary. Desktop frames, cursor movement, and
/// pointer mode remain inside the source/subscription path and never become
/// SwiftUI observation inputs.
public struct SpiceDesktopView: NSViewRepresentable {
    public var desktop: SpiceDesktopSource
    public var surface: SpiceSurfaceSelection
    public var onInput: @MainActor @Sendable (SpiceClientInput) -> Void

    public init(
        desktop: SpiceDesktopSource,
        surface: SpiceSurfaceSelection = .primary,
        onInput: @escaping @MainActor @Sendable (SpiceClientInput) -> Void
    ) {
        self.desktop = desktop
        self.surface = surface
        self.onInput = onInput
    }

    public func makeNSView(context: Context) -> NSView {
        SpiceFramebufferView(
            desktop: desktop,
            surface: surface,
            onInput: onInput
        )
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SpiceFramebufferView)?.update(
            desktop: desktop,
            surface: surface,
            onInput: onInput
        )
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: Void) {
        (nsView as? SpiceFramebufferView)?.prepareForDismantle()
    }
}

@MainActor
private final class SpiceDisplayLinkTarget: NSObject {
    weak var owner: SpiceFramebufferView?

    @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
        owner?.displayLinkDidFire(displayLink)
    }
}

@MainActor
package final class SpiceFramebufferView: NSView {
    private enum SnapshotApplicationResult {
        case consumed
        case retry
    }

    private var desktop: SpiceDesktopSource
    private var surface: SpiceSurfaceSelection
    private var subscription: SpiceDesktopSubscription?
    private var subscriptionDemand: SpiceDesktopDemand = .none
    private var readyLatch = SpiceDesktopReadyLatch()
    private let displayLinkTarget = SpiceDisplayLinkTarget()
    private var desktopDisplayLink: CADisplayLink?
    private let clock = ContinuousClock()

    private var desktopGeneration: UInt64?
    private var selectedRevision: SpiceFrameRevision?
    private var acknowledgedRevision: SpiceFrameRevision?
    private var frameGeometry: SpiceDesktopFrameGeometry?
    private var cpuFrame: SpiceFrame?
    private var cursorState: SpiceCursorState?
    private var pointerMode: SpicePointerMode = .absolute
    private var requiresFrameRedraw = true
    private var metalFailureRecovery = SpiceMetalFailureRecoveryPolicy()
    private var forcedCPUFallbackRevision: SpiceFrameRevision?
    private var presentationDiagnostics: SpicePresentationDiagnostics?

    private var windowObservers: [NSObjectProtocol] = []
    private var onInput: @MainActor @Sendable (SpiceClientInput) -> Void
    private var trackingArea: NSTrackingArea?
    private var pressedScanCodes: Set<UInt32> = []
    private let metalView: SpiceMetalFrameView?
    private let cursorOverlay = SpiceCursorOverlayView()
    private var isUsingMetal = false
    private var lastContentRectangle: NSRect = .zero
    private var systemCursorDescriptor: SpiceSystemCursorDescriptor?
    private var systemCursor: NSCursor = .arrow
    private let pointerCapture = SpicePointerCaptureController.system()

    package override var isFlipped: Bool { true }
    package override var acceptsFirstResponder: Bool { true }

    package init(
        desktop: SpiceDesktopSource,
        surface: SpiceSurfaceSelection,
        onInput: @escaping @MainActor @Sendable (SpiceClientInput) -> Void
    ) {
        self.desktop = desktop
        self.surface = surface
        self.onInput = onInput
        presentationDiagnostics = desktop.presentationDiagnostics
        metalView = SpiceMetalFrameView(
            presentationDiagnostics: desktop.presentationDiagnostics
        )
        super.init(frame: .zero)

        if let metalView {
            addSubview(metalView)
        }
        addSubview(cursorOverlay)
        displayLinkTarget.owner = self
        let displayLink = displayLink(
            target: displayLinkTarget,
            selector: #selector(SpiceDisplayLinkTarget.displayLinkDidFire(_:))
        )
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
        desktopDisplayLink = displayLink
        configureSubscription()
        updateCursorPresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        desktopDisplayLink?.invalidate()
    }

    package func update(
        desktop: SpiceDesktopSource,
        surface: SpiceSurfaceSelection,
        onInput: @escaping @MainActor @Sendable (SpiceClientInput) -> Void
    ) {
        self.onInput = onInput
        guard self.desktop !== desktop || self.surface != surface else {
            return
        }
        self.desktop = desktop
        self.surface = surface
        presentationDiagnostics = desktop.presentationDiagnostics
        metalView?.setPresentationDiagnostics(desktop.presentationDiagnostics)
        configureSubscription()
    }

    private func configureSubscription() {
        subscription?.setDemand(.none)
        subscription?.setUpdateHandler(nil)
        subscription?.cancel()
        subscription = nil
        subscriptionDemand = .none
        readyLatch.discard()
        readyLatch = SpiceDesktopReadyLatch()
        resetDesktopState()

        let subscription = desktop.subscribe(surface: surface)
        self.subscription = subscription
        let readyLatch = readyLatch
        subscription.setUpdateHandler { [weak self] snapshot in
            guard readyLatch.offer(snapshot) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.readyLatch === readyLatch else { return }
                self.wakeDisplayLinkIfNeeded()
            }
        }
        updateDesktopDemand(force: true)
    }

    private func resetDesktopState() {
        desktopGeneration = nil
        selectedRevision = nil
        acknowledgedRevision = nil
        frameGeometry = nil
        cpuFrame = nil
        cursorState = nil
        pointerMode = .absolute
        requiresFrameRedraw = true
        metalFailureRecovery.reset()
        forcedCPUFallbackRevision = nil
        isUsingMetal = false
        metalView?.discardPresentedContent()
        updateSubviewGeometry(requestLatestFrame: false)
        updateCursorPresentation()
        needsDisplay = true
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObservers()
        guard let window else {
            releasePointerCapture()
            updateDesktopDemand(force: true)
            return
        }

        window.acceptsMouseMovedEvents = true
        let center = NotificationCenter.default
        let releaseNames: [Notification.Name] = [
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
        ]
        windowObservers.append(contentsOf: releaseNames.map { name in
            center.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.releasePointerCapture()
                }
            }
        })
        let visibilityNames: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        windowObservers.append(contentsOf: visibilityNames.map { name in
            center.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateDesktopDemand()
                }
            }
        })
        updateSubviewGeometry(requestLatestFrame: true)
        updateDesktopDemand(force: true)
    }

    package override func viewDidHide() {
        super.viewDidHide()
        updateDesktopDemand()
    }

    package override func viewDidUnhide() {
        super.viewDidUnhide()
        updateDesktopDemand()
    }

    package override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSubviewGeometry(requestLatestFrame: true)
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        for observer in windowObservers {
            center.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    private func desiredDesktopDemand() -> SpiceDesktopDemand {
        guard let window,
              !window.isMiniaturized,
              window.occlusionState.contains(.visible),
              !isHiddenOrHasHiddenAncestor,
              bounds.width > 0,
              bounds.height > 0,
              visibleRect.width > 0,
              visibleRect.height > 0
        else {
            return .none
        }
        return .visible
    }

    private func updateDesktopDemand(force: Bool = false) {
        let demand = desiredDesktopDemand()
        guard force || demand != subscriptionDemand else { return }
        subscriptionDemand = demand
        subscription?.setDemand(demand)
        switch demand {
        case .none:
            readyLatch.discard()
            pauseDisplayLinkIfIdle()
            cpuFrame = nil
            isUsingMetal = false
            requiresFrameRedraw = true
            metalView?.discardPresentedContent()
        case .visible:
            wakeDisplayLinkIfNeeded()
        }
    }

    private func wakeDisplayLinkIfNeeded() {
        guard subscriptionDemand == .visible,
              !readyLatch.isEmpty,
              let desktopDisplayLink,
              desktopDisplayLink.isPaused
        else {
            return
        }
        presentationDiagnostics?.recordDesktopDisplayLinkWakeup()
        desktopDisplayLink.isPaused = false
    }

    private func pauseDisplayLinkIfIdle() {
        guard let desktopDisplayLink, !desktopDisplayLink.isPaused else { return }
        desktopDisplayLink.isPaused = true
        presentationDiagnostics?.recordDesktopDisplayLinkIdlePause()
    }

    fileprivate func displayLinkDidFire(_ displayLink: CADisplayLink) {
        presentationDiagnostics?.recordDesktopDisplayLinkTick()
        guard subscriptionDemand == .visible else {
            pauseDisplayLinkIfIdle()
            return
        }
        guard let snapshot = readyLatch.take() else {
            pauseDisplayLinkIfIdle()
            return
        }

        switch apply(snapshot, requestedAt: clock.now) {
        case .consumed:
            if readyLatch.isEmpty {
                pauseDisplayLinkIfIdle()
            }
        case .retry:
            readyLatch.restoreIfEmpty(snapshot)
            wakeDisplayLinkIfNeeded()
        }
    }

    private func apply(
        _ snapshot: SpiceDesktopSnapshot,
        requestedAt: ContinuousClock.Instant
    ) -> SnapshotApplicationResult {
        if let desktopGeneration, snapshot.generation < desktopGeneration {
            return .consumed
        }
        if desktopGeneration != snapshot.generation {
            desktopGeneration = snapshot.generation
            selectedRevision = nil
            acknowledgedRevision = nil
            frameGeometry = nil
            cpuFrame = nil
            requiresFrameRedraw = true
            metalFailureRecovery.reset()
            forcedCPUFallbackRevision = nil
            isUsingMetal = false
            metalView?.discardPresentedContent()
        }

        cursorState = snapshot.cursor
        pointerMode = snapshot.pointerMode
        if pointerMode == .absolute {
            releasePointerCapture()
        }

        guard let update = snapshot.frame else {
            let hadFrame = frameGeometry != nil || selectedRevision != nil
            selectedRevision = nil
            acknowledgedRevision = nil
            frameGeometry = nil
            cpuFrame = nil
            requiresFrameRedraw = false
            metalFailureRecovery.reset()
            forcedCPUFallbackRevision = nil
            isUsingMetal = false
            metalView?.discardPresentedContent()
            if hadFrame {
                updateSubviewGeometry(requestLatestFrame: false)
                needsDisplay = true
            }
            updateCursorPresentation()
            return .consumed
        }

        if let forcedCPUFallbackRevision,
           forcedCPUFallbackRevision != update.revision {
            self.forcedCPUFallbackRevision = nil
        }

        let result: SpiceMetalFramePresentationResult? = SpiceDesktopPresentationPolicy
            .withFramebufferPresentationIfNeeded(
            selectedRevision: selectedRevision,
            updateRevision: update.revision,
            requiresRedraw: requiresFrameRedraw
        ) {
            let updatedGeometry = SpiceDesktopFrameGeometry(
                width: update.frame.width,
                height: update.frame.height
            )
            if self.frameGeometry != updatedGeometry {
                self.frameGeometry = updatedGeometry
                self.updateSubviewGeometry(requestLatestFrame: false)
            }
            if self.forcedCPUFallbackRevision == update.revision {
                self.presentationDiagnostics?.recordCPUFallback(.metalCommandFailure)
                self.metalView?.discardPresentedContent()
                return .cpuFallback(.metalCommandFailure)
            }
            if let metalView = self.metalView {
                let attempt = self.metalFailureRecovery.beginAttempt(
                    for: update.revision
                )
                let result = metalView.present(
                    update.frame,
                    requestedAt: requestedAt
                ) { [weak self] completion in
                    self?.metalCommandCompleted(
                        attempt,
                        completion: completion
                    )
                }
                if result != .committed {
                    self.metalFailureRecovery.cancelAttempt(attempt)
                }
                return result
            }
            self.presentationDiagnostics?.recordCPUFallback(.metalUnavailable)
            return .cpuFallback(.metalUnavailable)
        }
        guard let result else {
            updateCursorPresentation()
            return .consumed
        }

        switch result {
        case .committed:
            accept(update.revision)
            cpuFrame = nil
            isUsingMetal = true
            requiresFrameRedraw = false
            acknowledgeIfNeeded(update.revision)
            updateCursorPresentation()
            return .consumed
        case .cpuFallback:
            accept(update.revision)
            cpuFrame = update.frame
            isUsingMetal = false
            requiresFrameRedraw = false
            acknowledgeIfNeeded(update.revision)
            updateCursorPresentation()
            needsDisplay = true
            return .consumed
        case .gpuBusy, .drawableUnavailable:
            updateCursorPresentation()
            return .retry
        }
    }

    private func acknowledgeIfNeeded(_ revision: SpiceFrameRevision) {
        guard acknowledgedRevision != revision else { return }
        acknowledgedRevision = revision
        subscription?.acknowledgeFrame(revision)
    }

    private func metalCommandCompleted(
        _ attempt: SpiceMetalFailureRecoveryPolicy.Attempt,
        completion: SpiceMetalCommandCompletion
    ) {
        let action = metalFailureRecovery.commandCompleted(
            attempt,
            completion: completion,
            selectedRevision: selectedRevision
        )
        switch action {
        case .none:
            return
        case .requestLatest:
            requiresFrameRedraw = true
            subscription?.requestLatest()
        case .useCPUFallback:
            forcedCPUFallbackRevision = attempt.revision
            requiresFrameRedraw = true
            subscription?.requestLatest()
        }
    }

    private func accept(_ revision: SpiceFrameRevision) {
        if let selectedRevision,
           selectedRevision.surface == revision.surface,
           revision.value > selectedRevision.value {
            let revisionDelta = revision.value - selectedRevision.value
            guard revisionDelta > 1 else {
                self.selectedRevision = revision
                return
            }
            presentationDiagnostics?.recordMetalFramesSupersededBeforeDraw(
                revisionDelta - 1
            )
        }
        selectedRevision = revision
    }

    package override func layout() {
        super.layout()
        updateDesktopDemand()
        updateSubviewGeometry(requestLatestFrame: true)
    }

    @discardableResult
    private func updateSubviewGeometry(requestLatestFrame: Bool) -> Bool {
        if cursorOverlay.frame != bounds {
            cursorOverlay.frame = bounds
        }
        let contentRectangle: NSRect
        if let frameGeometry {
            contentRectangle = SpiceFrameDrawing.contentRectangle(
                in: bounds,
                frameWidth: frameGeometry.width,
                frameHeight: frameGeometry.height
            )
        } else {
            contentRectangle = .zero
        }
        let contentChanged = contentRectangle != lastContentRectangle
        lastContentRectangle = contentRectangle
        if metalView?.frame != contentRectangle {
            metalView?.frame = contentRectangle
        }
        let backingScaleFactor = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        let drawableChanged = metalView?.updateDrawableSize(
            backingScaleFactor: backingScaleFactor
        ) ?? false
        cursorOverlay.update(
            frameGeometry: frameGeometry,
            cursorState: cursorState
        )
        updateSystemCursor()

        let presentationGeometryChanged = contentChanged || drawableChanged
        if contentChanged {
            needsDisplay = true
        }
        if requestLatestFrame,
           presentationGeometryChanged,
           selectedRevision != nil,
           subscriptionDemand == .visible {
            requiresFrameRedraw = true
            subscription?.requestLatest()
        }
        return presentationGeometryChanged
    }

    package override func resetCursorRects() {
        addCursorRect(bounds, cursor: systemCursor)
    }

    package override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    package override func updateTrackingAreas() {
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

    package override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        guard !isUsingMetal,
              let cpuFrame,
              let image = SpiceFrameDrawing.makeImage(cpuFrame)
        else {
            return
        }
        let destination = SpiceFrameDrawing.contentRectangle(
            in: bounds,
            frameWidth: cpuFrame.width,
            frameHeight: cpuFrame.height
        )
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

    package override func keyDown(with event: NSEvent) {
        guard let scanCode = MacXTScanCode.map[event.keyCode] else {
            super.keyDown(with: event)
            return
        }
        pressedScanCodes.insert(scanCode)
        onInput(.keyDown(scanCode: scanCode))
    }

    package override func keyUp(with event: NSEvent) {
        guard let scanCode = MacXTScanCode.map[event.keyCode] else {
            super.keyUp(with: event)
            return
        }
        pressedScanCodes.remove(scanCode)
        onInput(.keyUp(scanCode: scanCode))
    }

    package override func flagsChanged(with event: NSEvent) {
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

    package override func resignFirstResponder() -> Bool {
        for scanCode in pressedScanCodes {
            onInput(.keyUp(scanCode: scanCode))
        }
        pressedScanCodes.removeAll(keepingCapacity: true)
        releasePointerCapture()
        return super.resignFirstResponder()
    }

    package override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        capturePointerIfNeeded()
        onInput(.mousePress(.left))
    }

    package override func mouseUp(with event: NSEvent) {
        onInput(.mouseRelease(.left))
    }

    package override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        capturePointerIfNeeded()
        onInput(.mousePress(.right))
    }

    package override func rightMouseUp(with event: NSEvent) {
        onInput(.mouseRelease(.right))
    }

    package override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        capturePointerIfNeeded()
        onInput(.mousePress(mouseButton(number: event.buttonNumber)))
    }

    package override func otherMouseUp(with event: NSEvent) {
        onInput(.mouseRelease(mouseButton(number: event.buttonNumber)))
    }

    package override func mouseMoved(with event: NSEvent) { sendMotion(event) }
    package override func mouseDragged(with event: NSEvent) { sendMotion(event) }
    package override func rightMouseDragged(with event: NSEvent) { sendMotion(event) }
    package override func otherMouseDragged(with event: NSEvent) { sendMotion(event) }

    package override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
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
            guard let frameGeometry,
                  frameGeometry.width > 0,
                  frameGeometry.height > 0
            else {
                return
            }
            let point = convert(event.locationInWindow, from: nil)
            let destination = SpiceFrameDrawing.contentRectangle(
                in: bounds,
                frameWidth: frameGeometry.width,
                frameHeight: frameGeometry.height
            )
            guard destination.contains(point) else { return }
            let x = min(frameGeometry.width - 1, max(0, Int(
                ((point.x - destination.minX) / destination.width)
                    * CGFloat(frameGeometry.width)
            )))
            let y = min(frameGeometry.height - 1, max(0, Int(
                ((point.y - destination.minY) / destination.height)
                    * CGFloat(frameGeometry.height)
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

    package func releasePointerCapture() {
        pointerCapture.release()
        updateCursorPresentation()
    }

    @objc func releaseSpicePointerCapture(_ sender: Any?) {
        releasePointerCapture()
    }

    package func prepareForDismantle() {
        releasePointerCapture()
        removeWindowObservers()
        subscriptionDemand = .none
        subscription?.setDemand(.none)
        subscription?.setUpdateHandler(nil)
        subscription?.cancel()
        subscription = nil
        readyLatch.discard()
        desktopDisplayLink?.invalidate()
        desktopDisplayLink = nil
        displayLinkTarget.owner = nil
        metalView?.discardPresentedContent()
    }

    private func updateCursorPresentation() {
        let usesOverlay = SpiceDesktopPresentationPolicy.cursorLayer(
            for: pointerMode,
            isPointerCaptured: pointerCapture.isCaptured
        ) == .overlay
        cursorOverlay.isHidden = !usesOverlay
        cursorOverlay.update(
            frameGeometry: frameGeometry,
            cursorState: usesOverlay ? cursorState : nil
        )
        updateSystemCursor()
    }

    private func updateSystemCursor() {
        let destinationSize = frameGeometry.map {
            SpiceFrameDrawing.contentRectangle(
                in: bounds,
                frameWidth: $0.width,
                frameHeight: $0.height
            ).size
        } ?? .zero
        let descriptor = SpiceDesktopPresentationPolicy.systemCursorDescriptor(
            for: pointerMode,
            cursorState: cursorState,
            frameSize: frameGeometry.map {
                CGSize(width: $0.width, height: $0.height)
            },
            destinationSize: destinationSize,
            isPointerCaptured: pointerCapture.isCaptured
        )
        guard descriptor != systemCursorDescriptor else { return }
        systemCursorDescriptor = descriptor
        systemCursor = SpiceFrameDrawing.makeSystemCursor(descriptor)
        window?.invalidateCursorRects(for: self)
    }

    private func clampedInt32(_ value: CGFloat) -> Int32 {
        guard value.isFinite else { return 0 }
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
    private let cursorLayer = CALayer()
    private var frameGeometry: SpiceDesktopFrameGeometry?
    private var cursorState: SpiceCursorState?
    private var imageKey: SpiceCursorImageCacheKey?
    private var cachedImage: CGImage?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let rootLayer = CALayer()
        rootLayer.masksToBounds = true
        layer = rootLayer
        cursorLayer.contentsGravity = .resize
        cursorLayer.magnificationFilter = .nearest
        cursorLayer.minificationFilter = .nearest
        cursorLayer.isHidden = true
        rootLayer.addSublayer(cursorLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    fileprivate func update(
        frameGeometry: SpiceDesktopFrameGeometry?,
        cursorState: SpiceCursorState?
    ) {
        self.frameGeometry = frameGeometry
        self.cursorState = cursorState
        refreshCursorLayer()
    }

    override func layout() {
        super.layout()
        refreshCursorLayer()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func refreshCursorLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let frameGeometry,
              frameGeometry.width > 0,
              frameGeometry.height > 0,
              let cursorState,
              cursorState.isVisible,
              let cursor = cursorState.image,
              cursor.format == .alpha,
              cursor.width > 0,
              cursor.height > 0
        else {
            cursorLayer.isHidden = true
            return
        }

        let key = SpiceCursorImageCacheKey(cursor)
        if imageKey != key {
            cachedImage = SpiceFrameDrawing.makeCursorImage(cursor)
            imageKey = key
            cursorLayer.contents = cachedImage
        }
        guard cachedImage != nil else {
            cursorLayer.isHidden = true
            return
        }

        let destination = SpiceFrameDrawing.contentRectangle(
            in: bounds,
            frameWidth: frameGeometry.width,
            frameHeight: frameGeometry.height
        )
        let scaleX = destination.width / CGFloat(frameGeometry.width)
        let scaleY = destination.height / CGFloat(frameGeometry.height)
        cursorLayer.frame = CGRect(
            x: destination.minX
                + (CGFloat(cursorState.x) - CGFloat(cursor.hotSpotX)) * scaleX,
            y: destination.minY
                + (CGFloat(cursorState.y) - CGFloat(cursor.hotSpotY)) * scaleY,
            width: CGFloat(cursor.width) * scaleX,
            height: CGFloat(cursor.height) * scaleY
        )
        cursorLayer.contentsScale = window?.backingScaleFactor ?? 1
        cursorLayer.isHidden = false
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
        guard frameWidth > 0,
              frameHeight > 0,
              bounds.width > 0,
              bounds.height > 0
        else {
            return .zero
        }
        let scale = min(
            bounds.width / CGFloat(frameWidth),
            bounds.height / CGFloat(frameHeight)
        )
        let size = NSSize(
            width: CGFloat(frameWidth) * scale,
            height: CGFloat(frameHeight) * scale
        )
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func makeImage(_ frame: SpiceFrame) -> CGImage? {
        makeBGRAImage(
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            pixels: frame.pixels
        )
    }

    static func makeCursorImage(_ cursor: SpiceCursorImage) -> CGImage? {
        guard cursor.format == .alpha else { return nil }
        let (bytesPerRow, rowOverflow) = cursor.width.multipliedReportingOverflow(by: 4)
        guard !rowOverflow else { return nil }
        return makeBGRAImage(
            width: cursor.width,
            height: cursor.height,
            bytesPerRow: bytesPerRow,
            pixels: cursor.data
        )
    }

    private static func makeBGRAImage(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixels: Data
    ) -> CGImage? {
        let (minimumBytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (expectedBytes, sizeOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard width > 0,
              height > 0,
              !rowOverflow,
              !sizeOverflow,
              bytesPerRow >= minimumBytesPerRow,
              pixels.count == expectedBytes,
              let provider = CGDataProvider(data: pixels as CFData)
        else {
            return nil
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
        ))
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
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
        guard let image = makeCursorImage(cursor) else { return .arrow }
        let size = NSSize(
            width: CGFloat(cursor.width) * scaleX,
            height: CGFloat(cursor.height) * scaleY
        )
        guard size.width > 0, size.height > 0 else { return .arrow }
        return NSCursor(
            image: NSImage(cgImage: image, size: size),
            hotSpot: NSPoint(
                x: CGFloat(cursor.hotSpotX) * scaleX,
                y: CGFloat(cursor.hotSpotY) * scaleY
            )
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
