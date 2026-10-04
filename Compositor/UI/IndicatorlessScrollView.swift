import AppKit
import SwiftUI

/// The tool rail scrolls when it overflows without showing or reserving space
/// for a macOS scroller, even when the system setting always shows scroll bars.
struct IndicatorlessScrollView<Content: View>: NSViewRepresentable {
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> IndicatorlessScrollContainer {
        IndicatorlessScrollContainer(rootView: AnyView(content()))
    }

    func updateNSView(_ view: IndicatorlessScrollContainer, context: Context) {
        view.host.rootView = AnyView(content())
        view.host.invalidateIntrinsicContentSize()
        view.updateDocumentSize()
    }
}

/// Not nested in the generic view: as a generic class its deinit crashes the Release optimizer (Swift 6.3.3).
final class IndicatorlessScrollContainer: NSScrollView {
    let host: NSHostingView<AnyView>

    init(rootView: AnyView) {
        host = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = false
        horizontalScrollElasticity = .none
        documentView = host
        updateDocumentSize()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateDocumentSize()
    }

    func updateDocumentSize() {
        let height = host.fittingSize.height
        let size = NSSize(width: 56, height: height)
        if host.frame.size != size { host.setFrameSize(size) }
        verticalScrollElasticity = height > contentView.bounds.height + 1 ? .allowed : .none
    }
}
