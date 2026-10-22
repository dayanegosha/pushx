import SwiftUI

enum AppFont {
    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .ultraLight: name = "Geologica-Thin"
        case .thin: name = "Geologica-Thin_ExtraLight"
        case .light: name = "Geologica-Thin_Light"
        case .medium: name = "Geologica-Thin_Medium"
        case .semibold: name = "Geologica-Thin_SemiBold"
        case .bold: name = "Geologica-Thin_Bold"
        case .heavy: name = "Geologica-Thin_ExtraBold"
        case .black: name = "Geologica-Thin_Black"
        default: name = "Geologica-Thin_Regular"
        }
        return .custom(name, size: size, relativeTo: .body)
    }

    static func numeric(_ size: CGFloat) -> Font {
        .custom("Geologica-Thin_Regular", fixedSize: size).monospacedDigit()
    }

    static func counter(_ size: CGFloat) -> Font {
        .custom("Geologica-Thin_Light", fixedSize: size)
    }
}

extension Color {
    static let canvas = Color(uiColor: .systemBackground)
    static let panel = Color(uiColor: .secondarySystemBackground)
    static let ink = Color.primary
}

struct FilledButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(AppFont.text(16, weight: .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 19)
            .foregroundStyle(Color.canvas).background(Color.ink, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.32)
    }
}

struct PageTitle: View {
    let title: String

    var body: some View {
        Text(title).font(AppFont.text(36, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InfoCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.system(size: 19, weight: .regular))
                .foregroundStyle(.secondary).frame(width: 25).padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(AppFont.text(15, weight: .semibold))
                Text(detail).font(AppFont.text(13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color.panel, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct StatusNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle").font(AppFont.text(13)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color.panel, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct PushMark: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(10 / 64, 22 / 64))
        path.addCurve(to: point(32 / 64, 42 / 64), control1: point(21 / 64, 22 / 64), control2: point(21 / 64, 42 / 64))
        path.addCurve(to: point(54 / 64, 22 / 64), control1: point(43 / 64, 42 / 64), control2: point(43 / 64, 22 / 64))
        return path
    }
}

struct Brand: View {
    var body: some View {
        HStack(spacing: 10) {
            PushMark().stroke(Color.ink, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                .frame(width: 28, height: 28)
            Text("pushx").font(AppFont.text(20, weight: .semibold))
        }.accessibilityElement(children: .ignore).accessibilityLabel("pushx")
    }
}
