import SwiftUI

enum AppFont {
    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .ultraLight: name = "Onest-Thin"
        case .thin: name = "Onest-ExtraLight"
        case .light: name = "Onest-Light"
        case .medium: name = "Onest-Medium"
        case .semibold: name = "Onest-SemiBold"
        case .bold: name = "Onest-Bold"
        case .heavy: name = "Onest-ExtraBold"
        case .black: name = "Onest-Black"
        default: name = "Onest-Regular"
        }
        return .custom(name, size: size, relativeTo: .body)
    }

    static func numeric(_ size: CGFloat) -> Font {
        .custom("Onest-Regular", fixedSize: size).monospacedDigit()
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

struct UpraMark: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        for offset: CGFloat in [0, 0.33] {
            path.move(to: point(0.18, 0.43 + offset))
            path.addLine(to: point(0.43, 0.18 + offset))
            path.addQuadCurve(to: point(0.57, 0.18 + offset), control: point(0.50, 0.11 + offset))
            path.addLine(to: point(0.82, 0.43 + offset))
        }
        return path
    }
}

struct Brand: View {
    var body: some View {
        HStack(spacing: 10) {
            UpraMark().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .frame(width: 28, height: 28)
            Text("UPRA").font(AppFont.text(18, weight: .bold)).tracking(2.5)
        }.accessibilityElement(children: .ignore).accessibilityLabel("UPRA")
    }
}
