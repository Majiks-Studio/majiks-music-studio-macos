import Foundation
import AVFoundation

protocol StudioMicrophonePermission: Sendable {
    func requestIfNeeded() async -> Bool
}

struct AlwaysAuthorizedMicrophonePermission: StudioMicrophonePermission {
    func requestIfNeeded() async -> Bool { true }
}

struct AVFoundationMicrophonePermission: StudioMicrophonePermission {
    func requestIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default: return false
        }
    }
}
