import SwiftUI
import AppKit

struct BlendModePicker: NSViewRepresentable {
    let session: EditorSession
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        // Grouped as Photoshop groups them — darkening, lightening, contrast, comparative, component —
        // with a line between, so a long list stays readable.
        for (index, group) in LayerBlendMode.groups.enumerated() {
            if index > 0 { button.menu?.addItem(.separator()) }
            for mode in group {
                button.addItem(withTitle: mode.localizedName)
                button.lastItem?.representedObject = mode.rawValue
            }
        }
        button.menu?.delegate = context.coordinator
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.setAccessibilityLabel(String(localized: "Blend mode"))
        // A capsule like the SwiftUI buttons and menus (`roundedControls`), which don't reach this AppKit pop-up.
        button.useCapsuleBorder()
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        button.isEnabled = session.canEditAppearance
        if !context.coordinator.tracking {
            Self.select(session.activeLayer?.blendMode ?? .normal, in: button)
        }
    }
    /// Items are matched by mode, not title, since titles are localized.
    static func mode(of item: NSMenuItem) -> LayerBlendMode? {
        (item.representedObject as? String).flatMap(LayerBlendMode.init(rawValue:))
    }
    static func select(_ mode: LayerBlendMode, in button: NSPopUpButton) {
        button.select(button.itemArray.first { Self.mode(of: $0) == mode })
    }
    static func dismantleNSView(_ button: NSPopUpButton, coordinator: Coordinator) {
        if coordinator.tracking { coordinator.session.previewBlendMode(nil, for: nil) }
        button.menu?.delegate = nil
    }
    final class Coordinator: NSObject, NSMenuDelegate {
        let session: EditorSession
        var tracking = false
        private var layerID: UUID?
        private var highlightedMode: LayerBlendMode?
        init(session: EditorSession) { self.session = session }
        func menuWillOpen(_ menu: NSMenu) {
            tracking = true
            layerID = session.activeLayerID
            highlightedMode = nil
        }
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            // AppKit briefly reports no highlighted item while dismissing the menu.
            // Keep the last preview alive until the selection action has committed so
            // the canvas never flashes back to the layer's previous mode.
            guard let mode = item.flatMap(BlendModePicker.mode(of:)) else { return }
            highlightedMode = mode
            session.previewBlendMode(mode, for: layerID)
        }
        func menuDidClose(_ menu: NSMenu) {
            tracking = false
            // A chosen item's action runs as the menu finishes closing. Clearing on the
            // next turn lets that action replace the preview with the committed mode;
            // when the menu was cancelled, this simply restores the original mode.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.tracking else { return }
                self.session.previewBlendMode(nil, for: nil)
            }
        }
        @objc func choose(_ button: NSPopUpButton) {
            guard session.activeLayerID == layerID,
                  let mode = highlightedMode ?? button.selectedItem.flatMap(BlendModePicker.mode(of:)) else { return }
            session.setLayerBlendMode(mode)
            BlendModePicker.select(mode, in: button)
            highlightedMode = nil
            session.refreshCanvasPreview?()
        }
    }
}

extension NSPopUpButton {
    /// Capsule-shaped on macOS 26; earlier systems have no border shape to choose and keep the standard bezel.
    func useCapsuleBorder() {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { borderShape = .capsule }
        #endif
    }
}
