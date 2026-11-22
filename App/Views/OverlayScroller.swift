import AppKit
import SwiftUI

extension View {
    /// Makes the enclosing `ScrollView` use the thin overlay scroller (the trackpad style, which
    /// fades out when idle) even when macOS would show the wide legacy one, e.g. with a mouse
    /// attached and "Show scroll bars" set to Automatic. Apply it to the ScrollView's content.
    func overlayScroller() -> some View {
        background(OverlayScrollerSetter())
    }
}

private struct OverlayScrollerSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ nsView: ProbeView, context: Context) { nsView.apply() }

    final class ProbeView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            if observer == nil {
                // NSScrollView resets its style to the system preference when that changes.
                observer = NotificationCenter.default.addObserver(
                    forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    DispatchQueue.main.async { self?.apply() }
                }
            }
        }

        func apply() {
            guard let scrollView = enclosingScrollView, scrollView.scrollerStyle != .overlay else { return }
            scrollView.scrollerStyle = .overlay
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
