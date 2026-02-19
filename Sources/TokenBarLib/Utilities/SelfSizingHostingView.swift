import AppKit
import SwiftUI

/// An NSView wrapper around NSHostingView that dynamically resizes
/// when its SwiftUI content changes size. Designed for use as an
/// NSMenuItem's `view` where the menu needs to grow/shrink when
/// content expands (e.g. disclosure triangles, accordion sections).
///
/// Uses a subclassed NSHostingView to detect when SwiftUI invalidates
/// its intrinsic content size, then forces the enclosing NSMenu to
/// re-layout so the menu grows downward instead of clipping content.
class SelfSizingHostingView<Content: View>: NSView {
    private let hostingView: LayoutTrackingHostingView<Content>
    private var lastKnownSize: NSSize = .zero

    init(rootView: Content) {
        hostingView = LayoutTrackingHostingView(rootView: rootView)
        super.init(frame: .zero)

        hostingView.onIntrinsicSizeInvalidated = { [weak self] in
            self?.recalculateSize()
        }

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let size = hostingView.fittingSize
        frame.size = size
        lastKnownSize = size
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        hostingView.fittingSize
    }

    override func layout() {
        super.layout()
        recalculateSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        recalculateSize()
    }

    private func recalculateSize() {
        let newSize = hostingView.fittingSize
        guard abs(newSize.width - lastKnownSize.width) > 0.5
           || abs(newSize.height - lastKnownSize.height) > 0.5 else { return }
        lastKnownSize = newSize
        frame.size = newSize
        invalidateIntrinsicContentSize()
        // Force the enclosing menu to re-layout for the new content size
        if let menu = enclosingMenuItem?.menu {
            menu.update()
            window?.layoutIfNeeded()
        }
    }
}

/// NSHostingView subclass that notifies when SwiftUI invalidates its
/// intrinsic content size (i.e. when the SwiftUI body changes dimensions).
private class LayoutTrackingHostingView<Content: View>: NSHostingView<Content> {
    var onIntrinsicSizeInvalidated: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        // Dispatch async to avoid re-entrant layout during the current pass
        DispatchQueue.main.async { [weak self] in
            self?.onIntrinsicSizeInvalidated?()
        }
    }
}
