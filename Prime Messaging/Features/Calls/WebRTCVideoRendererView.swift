import SwiftUI

#if os(iOS) && canImport(WebRTC) && canImport(UIKit)
import UIKit
import WebRTC

struct WebRTCVideoRendererView: UIViewRepresentable {
    enum StreamKind {
        case local
        case remote
    }

    let stream: StreamKind
    @ObservedObject private var callManager = InternetCallManager.shared

    func makeCoordinator() -> Coordinator {
        Coordinator(stream: stream)
    }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let renderer = RTCMTLVideoView(frame: .zero)
        renderer.videoContentMode = .scaleAspectFill
        renderer.clipsToBounds = true
        renderer.backgroundColor = .black
        renderer.transform = stream == .local
            ? CGAffineTransform(scaleX: -1, y: 1)
            : .identity
        context.coordinator.renderer.targetView = renderer
        context.coordinator.renderer.onFrameRendered = { [weak callManager] in
            guard context.coordinator.stream == .remote else { return }
            Task { @MainActor [weak callManager] in
                callManager?.noteRemoteVideoFrameRendered()
            }
        }
        attach(renderer: context.coordinator.renderer, stream: context.coordinator.stream)
        return renderer
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        uiView.transform = context.coordinator.stream == .local
            ? CGAffineTransform(scaleX: -1, y: 1)
            : .identity
        context.coordinator.renderer.targetView = uiView
        attach(renderer: context.coordinator.renderer, stream: context.coordinator.stream)
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        detach(renderer: coordinator.renderer, stream: coordinator.stream)
        coordinator.renderer.onFrameRendered = nil
        coordinator.renderer.targetView = nil
    }

    private func attach(renderer: RTCVideoRenderer, stream: StreamKind) {
        switch stream {
        case .local:
            callManager.attachLocalVideoRenderer(renderer)
        case .remote:
            callManager.attachRemoteVideoRenderer(renderer)
        }
    }

    private static func detach(renderer: RTCVideoRenderer, stream: StreamKind) {
        let manager = InternetCallManager.shared
        switch stream {
        case .local:
            manager.detachLocalVideoRenderer(renderer)
        case .remote:
            manager.detachRemoteVideoRenderer(renderer)
        }
    }

    final class Coordinator {
        let stream: StreamKind
        let renderer = FrameAwareVideoRenderer()

        init(stream: StreamKind) {
            self.stream = stream
        }
    }
}

final class FrameAwareVideoRenderer: NSObject, RTCVideoRenderer {
    weak var targetView: RTCMTLVideoView?
    var onFrameRendered: (() -> Void)?

    func setSize(_ size: CGSize) {
        targetView?.setSize(size)
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        targetView?.renderFrame(frame)
        if frame != nil {
            onFrameRendered?()
        }
    }
}
#else
struct WebRTCVideoRendererView: View {
    enum StreamKind {
        case local
        case remote
    }

    let stream: StreamKind

    var body: some View {
        Color.clear
    }
}
#endif
