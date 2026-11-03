import Foundation

@MainActor public protocol AudioCapturing: AnyObject {
    var onChunk: ((AudioChunk) -> Void)? { get set }
    var onLevel: ((AudioRole, Float) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func start() async throws
    func stop()
}
extension AudioCaptureController: AudioCapturing {}
