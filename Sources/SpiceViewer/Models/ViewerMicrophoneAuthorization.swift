@preconcurrency import AVFoundation

package enum ViewerMicrophoneAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

@MainActor
package protocol ViewerMicrophoneAuthorizing {
    func authorizationStatus() -> ViewerMicrophoneAuthorization
    func requestAccess() async -> Bool
}

@MainActor
package struct SystemViewerMicrophoneAuthorizer: ViewerMicrophoneAuthorizing {
    package init() {}

    package func authorizationStatus() -> ViewerMicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .restricted:
            .restricted
        case .authorized:
            .authorized
        @unknown default:
            .restricted
        }
    }

    package func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
