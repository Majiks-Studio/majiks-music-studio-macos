import SwiftUI

// MARK: - Toast Style

enum ToastStyle {
    case success, warning, error, info

    var color: Color {
        switch self {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .info: return .blue
        }
    }

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

// MARK: - How long a toast stays up

enum ToastDuration {
    /// An acknowledgement of something the user is already looking at.
    static let standard: Double = 3

    /// A result the user has to be able to ACT on — it names the remedy
    /// (Cmd-Z, or an engine refusal's cause). 3 s is the whole budget for
    /// noticing a toast, moving your eyes to it, reading it and deciding, and
    /// on a large display the noticing alone eats most of it. Destructive
    /// results and refusals use this.
    static let actionable: Double = 5
}

// MARK: - Which surface presents a toast

/// A toast is posted by a model that has no idea which window or pane the user
/// is looking at, so the PRESENTER is chosen here rather than at the call site.
///
/// `app` is the whole-window presenter (top of the main window, over the tab
/// strip). `studio` is the DAW's own presenter, which sits inside the Studio's
/// frame, next to where its gestures happen. Exactly one is active at a time —
/// two live presenters would draw the same toast twice.
enum ToastSurface: String, Sendable {
    case app
    case studio
}

// MARK: - Toast Message

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let style: ToastStyle
    /// Seconds at full opacity before the dismiss animation starts.
    let seconds: Double

    static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Toast Manager

@MainActor
class ToastManager: ObservableObject {
    static let shared = ToastManager()

    @Published var currentToast: ToastMessage?

    /// The surface currently responsible for drawing toasts. The Studio claims
    /// it while its tab is frontmost and gives it back on the way out, so the
    /// result of a Studio gesture appears in the Studio's own frame instead of
    /// at the far top of the window.
    @Published private(set) var activeSurface: ToastSurface = .app

    private var dismissTask: Task<Void, Never>?

    func show(
        _ message: String,
        style: ToastStyle = .info,
        seconds: Double = ToastDuration.standard
    ) {
        // Cancel any pending dismiss
        dismissTask?.cancel()

        withAnimation(.easeInOut(duration: 0.3)) {
            currentToast = ToastMessage(message: message, style: style, seconds: seconds)
        }

        dismissTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                currentToast = nil
            }
        }
    }

    /// Take over presentation. Idempotent.
    func claimSurface(_ surface: ToastSurface) {
        guard activeSurface != surface else { return }
        activeSurface = surface
    }

    /// Hand presentation back to the app-level overlay — but ONLY if this
    /// surface still holds it. A pane disappearing after something else already
    /// claimed must not yank the claim out from under it.
    func releaseSurface(_ surface: ToastSurface) {
        guard activeSurface == surface else { return }
        activeSurface = .app
    }

    /// Whether `surface` should draw the current toast. Pure, so the routing
    /// rule is testable without a view hierarchy.
    static func shouldRender(surface: ToastSurface, active: ToastSurface) -> Bool {
        surface == active
    }
}

// MARK: - Toast Overlay

struct ToastOverlay: View {
    /// Which presenter this instance is. The app-level one is the default, so
    /// the existing whole-window mount keeps its meaning.
    let surface: ToastSurface
    @ObservedObject var manager = ToastManager.shared

    init(surface: ToastSurface = .app) {
        self.surface = surface
    }

    var body: some View {
        VStack {
            if let toast = manager.currentToast,
               ToastManager.shouldRender(surface: surface, active: manager.activeSurface) {
                HStack(spacing: 8) {
                    Image(systemName: toast.style.icon)
                    Text(toast.message)
                        .font(.callout)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(toast.style.color.opacity(0.9))
                .foregroundStyle(.white)
                .clipShape(Capsule())
                .shadow(radius: 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(toast.message)
            }
            Spacer()
        }
        .padding(.top, 8)
        .allowsHitTesting(false)
    }
}
