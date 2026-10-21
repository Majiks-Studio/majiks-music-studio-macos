import SwiftUI
import AppKit

/// Manages pop-out windows for Library, Studio, and Help views
@MainActor
class WindowManager: ObservableObject {
    @Published var isLibraryWindowOpen = false
    @Published var isStudioWindowOpen = false
    @Published var isHelpWindowOpen = false

    static let shared = WindowManager()

    private init() {}

    func openLibraryWindow() {
        isLibraryWindowOpen = true
    }

    func closeLibraryWindow() {
        isLibraryWindowOpen = false
    }

    func openStudioWindow() {
        isStudioWindowOpen = true
    }

    func closeStudioWindow() {
        isStudioWindowOpen = false
    }

    func openHelpWindow() {
        isHelpWindowOpen = true
    }

    func closeHelpWindow() {
        isHelpWindowOpen = false
    }

    func toggleLibraryWindow() {
        isLibraryWindowOpen.toggle()
    }

    func toggleStudioWindow() {
        isStudioWindowOpen.toggle()
    }

    func toggleHelpWindow() {
        isHelpWindowOpen.toggle()
    }

    /// Ensure a window opens fully on a visible screen. macOS can restore or
    /// place the main window partly or wholly off-screen (observed on relaunch:
    /// origin well below the display, so the title bar is unreachable). This
    /// nudges the frame back onto the screen's visible area and shrinks it only
    /// if it is larger than that area. Only the frame is touched; the window's
    /// identity and content are left alone, so state restoration is unaffected.
    static func clampToVisibleFrame(_ window: NSWindow) {
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        var frame = window.frame

        // Shrink to fit if the window is larger than the visible area.
        frame.size.width = min(frame.size.width, visible.size.width)
        frame.size.height = min(frame.size.height, visible.size.height)

        // Pull the frame back inside the visible area on each edge.
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.size.width }
        if frame.minX < visible.minX { frame.origin.x = visible.minX }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.size.height }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }

        if frame != window.frame {
            window.setFrame(frame, display: true)
        }
    }
}
