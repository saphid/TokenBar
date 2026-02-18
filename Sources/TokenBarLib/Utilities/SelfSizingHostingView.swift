import AppKit
import SwiftUI

/// An NSView wrapper around NSHostingView that dynamically resizes
/// when its SwiftUI content changes size. Designed for use as an
/// NSMenuItem's `view` where the menu needs to grow/shrink when
/// content expands (e.g. disclosure triangles, accordion sections).
class SelfSizingHostingView<Content: View>: NSView {
    private let hostingView: NSHostingView<Content>

    init(rootView: Content) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        frame.size = hostingView.fittingSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        hostingView.fittingSize
    }

    override func layout() {
        super.layout()
        let newSize = hostingView.fittingSize
        if frame.size != newSize {
            frame.size = newSize
            invalidateIntrinsicContentSize()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-measure once we're in the menu's window
        let newSize = hostingView.fittingSize
        if frame.size != newSize {
            frame.size = newSize
            invalidateIntrinsicContentSize()
        }
    }
}
