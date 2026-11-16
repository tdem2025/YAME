import AppKit
import YAMECore
import SwiftUI

// MARK: - View state

/// Same as SwiftUI's `@State`, but a plain property wrapper instead of a macro.
/// Newer SDKs implement `@State` as a macro whose plugin ships only with the full
/// Xcode app; this lets YAME build with just the Command Line Tools too.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private var storage: SwiftUI.State<Value>

    init(wrappedValue: Value) {
        storage = SwiftUI.State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}

// MARK: - Liquid Glass helpers

extension View {
    /// A Liquid Glass panel.
    func glassCard(cornerRadius: CGFloat = 24, padding: CGFloat = 20) -> some View {
        self
            .padding(padding)
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

/// The current cover, blurred and blown up behind everything, so the glass picks up its colors.
struct AmbientBackground: View {
    let image: NSImage?

    var body: some View {
        Rectangle()
            .fill(.background)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 90, opaque: true)
                        .saturation(1.4)
                        .opacity(0.65)
                        .transition(.opacity)
                }
            }
            .overlay {
                LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.45), value: image)
    }
}

/// Small rounded cover used in the song list.
struct CoverThumbnail: View {
    let image: NSImage?
    var size: CGFloat = 38
    var corner: CGFloat = 7

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: corner))
        .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// A label above a plain text field, styled for glass.
struct GlassField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var monospacedDigits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(label, text: $text, prompt: Text(placeholder))
                .textFieldStyle(.plain)
                .font(monospacedDigits ? .body.monospacedDigit() : .body)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 9))
                .labelsHidden()
        }
    }
}

/// Bridges an optional Int to a text field.
func intText(_ binding: Binding<Int?>) -> Binding<String> {
    Binding(
        get: { binding.wrappedValue.map(String.init) ?? "" },
        set: { binding.wrappedValue = Int($0.filter(\.isNumber).prefix(4)) }
    )
}

func formatDuration(_ seconds: Double?) -> String {
    guard let s = seconds, s.isFinite else { return "" }
    let t = Int(s.rounded())
    return String(format: "%d:%02d", t / 60, t % 60)
}

/// Floating message at the bottom of the window.
struct BannerView: View {
    let banner: Banner

    var body: some View {
        Label(banner.text, systemImage: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(banner.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .glassEffect(.regular, in: .capsule)
    }
}

/// "Ready for your car" summary.
struct CarReadinessView: View {
    let issues: [CarCheck.Issue]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if issues.isEmpty {
                Label("Ready for your car", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.semibold))
            } else {
                Label(issues.contains(where: \.isProblem) ? "May not show correctly in your car" : "Almost car-ready",
                      systemImage: issues.contains(where: \.isProblem) ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(issues.contains(where: \.isProblem) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .font(.callout.weight(.semibold))
                ForEach(issues, id: \.self) { issue in
                    Label(issue.message, systemImage: issue.isProblem ? "xmark.circle" : "circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
