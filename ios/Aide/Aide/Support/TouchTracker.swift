import SwiftUI
import UIKit

/// Reports where a finger is on screen without taking part in touch handling: a passive recognizer
/// on the window that never cancels or delays touches, so buttons and scrolling work as usual.
struct TouchTracker: UIViewRepresentable {
    @Binding var point: CGPoint?
    @Binding var tapCount: Int

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        context.coordinator.attach = { [weak view] in
            guard let window = view?.window, context.coordinator.recognizer == nil else { return }
            let r = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handle(_:)))
            r.minimumPressDuration = 0
            r.allowableMovement = .greatestFiniteMagnitude
            r.cancelsTouchesInView = false
            r.delaysTouchesBegan = false
            r.delaysTouchesEnded = false
            r.delegate = context.coordinator
            window.addGestureRecognizer(r)
            context.coordinator.recognizer = r
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        DispatchQueue.main.async { context.coordinator.attach?() }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.recognizer?.view?.removeGestureRecognizer(coordinator.recognizer!)
        coordinator.recognizer = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TouchTracker
        var recognizer: UILongPressGestureRecognizer?
        var attach: (() -> Void)?
        init(_ parent: TouchTracker) { self.parent = parent }

        @objc func handle(_ r: UILongPressGestureRecognizer) {
            switch r.state {
            case .began:
                parent.tapCount += 1
                parent.point = r.location(in: nil)
            case .changed:
                parent.point = r.location(in: nil)
            default:
                parent.point = nil
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
