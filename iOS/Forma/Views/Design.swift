import SwiftUI

extension Color {
    static let canvas = Color(uiColor: .systemBackground)
    static let panel = Color(uiColor: .secondarySystemBackground)
    static let ink = Color.primary
}

struct FilledButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 20)
            .foregroundStyle(Color.canvas).background(Color.ink, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct PageTitle: View {
    let eyebrow: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow.uppercased()).font(.system(size: 10, weight: .bold)).tracking(3).foregroundStyle(.secondary)
            Text(title).font(.system(size: 38, weight: .bold, design: .rounded)).tracking(-1.5)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InfoCard: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.title3).frame(width: 25).padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).background(Color.panel, in: RoundedRectangle(cornerRadius: 24))
    }
}

struct StatusNote: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16).background(Color.panel, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct Brand: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.lefthalf.filled").font(.system(size: 22, weight: .bold)).rotationEffect(.degrees(-35))
            Text("FORMA").font(.system(size: 14, weight: .black)).tracking(5)
        }.accessibilityElement(children: .combine)
    }
}
