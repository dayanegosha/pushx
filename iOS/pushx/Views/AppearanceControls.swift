import SwiftUI
import UIKit

enum AccentChoice: String, CaseIterable, Identifiable {
    case violet, blue, mint, orange, rose, graphite

    var id: String { rawValue }
    var title: String { L.text("accent_" + rawValue) }
    static var current: AccentChoice {
        AccentChoice(rawValue: UserDefaults.standard.string(forKey: "accentColor") ?? "") ?? .violet
    }

    var color: Color {
        Color(uiColor: UIColor { traits in
            let hexRGB = traits.userInterfaceStyle == .dark ? self.palette.dark : self.palette.light
            return UIColor(red: CGFloat((hexRGB >> 16) & 0xFF) / 255,
                           green: CGFloat((hexRGB >> 8) & 0xFF) / 255,
                           blue: CGFloat(hexRGB & 0xFF) / 255, alpha: 1)
        })
    }

    private var palette: (light: UInt32, dark: UInt32) {
        switch self {
        case .violet: return (0x7454D8, 0xAA95FF)
        case .blue: return (0x2563D9, 0x7BA8FF)
        case .mint: return (0x087F6E, 0x65D7BA)
        case .orange: return (0xB85C12, 0xF3AF66)
        case .rose: return (0xBF3D6A, 0xF89BBB)
        case .graphite: return (0x34343B, 0xD0D0D6)
        }
    }
}

struct AppearanceMenuRow<Options: View>: View {
    let title: String
    let value: String
    @Binding var selection: String
    let identifier: String
    private let options: Options
    @AppStorage("accentColor") private var accent = AccentChoice.violet.rawValue

    init(title: String, value: String, selection: Binding<String>, identifier: String, @ViewBuilder options: () -> Options) {
        self.title = title
        self.value = value
        self._selection = selection
        self.identifier = identifier
        self.options = options()
    }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) { options }
        } label: {
            HStack(spacing: 12) {
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 12)
                Text(value).multilineTextAlignment(.trailing)
                    .foregroundStyle((AccentChoice(rawValue: accent) ?? .violet).color)
                    .accessibilityIdentifier(identifier + "_value")
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
                    .foregroundStyle((AccentChoice(rawValue: accent) ?? .violet).color)
                    .accessibilityHidden(true)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityIdentifier(identifier)
    }
}

struct AccentPickerRow: View {
    @AppStorage("accentColor") private var accent = AccentChoice.violet.rawValue
    private var selection: AccentChoice { AccentChoice(rawValue: accent) ?? .violet }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
            HStack {
                Text(L.text("accent_color")).font(AppFont.text(15, weight: .medium))
                Spacer()
                Text(selection.title).font(AppFont.text(12)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L.text("accent_color")).font(AppFont.text(15, weight: .medium))
                Text(selection.title).font(AppFont.text(12)).foregroundStyle(.secondary)
            }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(AccentChoice.allCases) { choice in
                        Button {
                            withAnimation(.smooth(duration: 0.18)) { accent = choice.rawValue }
                        } label: {
                            ZStack {
                                Circle().fill(choice.color).frame(width: 34, height: 34)
                                if selection == choice {
                                    Image(systemName: "checkmark")
                                        .font(AppFont.text(13, weight: .bold))
                                        .foregroundStyle(Color.canvas)
                                    Circle().strokeBorder(Color.primary, lineWidth: 1.5)
                                        .frame(width: 44, height: 44)
                                }
                            }.frame(width: 44, height: 44).contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.title)
                        .accessibilityAddTraits(selection == choice ? .isSelected : [])
                        .accessibilityIdentifier("accent_" + choice.rawValue)
                    }
                }.padding(.vertical, 2)
            }
        }.padding(.vertical, 4)
    }
}

struct GoalEditorView: View {
    @Binding var goal: Int
    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool
    @State private var draft: String
    @State private var sliderValue: Double
    private let presets = [20, 50, 100, 200]

    init(goal: Binding<Int>) {
        _goal = goal
        let value = min(1000, max(1, goal.wrappedValue))
        _draft = State(initialValue: String(value))
        _sliderValue = State(initialValue: Double(value))
    }

    private var validatedGoal: Int? {
        guard let value = Int(draft), (1...1000).contains(value) else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                AdaptiveContent(maxWidth: 600) {
                VStack(alignment: .leading, spacing: 28) {
                    Text(L.text("goal_title"))
                        .font(AppFont.text(30, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 10) {
                        TextField(L.text("goal_input"), text: $draft)
                            .font(AppFont.numeric(76)).monospacedDigit()
                            .multilineTextAlignment(.center)
                            .keyboardType(.numberPad)
                            .focused($inputFocused)
                            .tint(AccentChoice.current.color)
                            .accessibilityLabel(L.text("goal_input"))
                            .accessibilityHint(L.text("goal_range"))
                            .accessibilityIdentifier("goal_input")
                            .onChange(of: draft) { _, value in
                                let digits = String(value.filter { "0123456789".contains($0) })
                                if value != digits { draft = digits }
                                if let value = Int(digits), (1...1000).contains(value) {
                                    sliderValue = Double(value)
                                }
                            }
                        Text(L.text("goal_range")).font(AppFont.text(12))
                            .foregroundStyle(validatedGoal == nil ? Color.red : Color.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
                    .background(Color.panel, in: RoundedRectangle(cornerRadius: 28))
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L.text("goal_presets")).font(AppFont.text(13, weight: .medium)).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            ForEach(presets, id: \.self) { preset in
                                Button {
                                    draft = String(preset)
                                    sliderValue = Double(preset)
                                    inputFocused = false
                                } label: {
                                    Text(String(preset)).font(AppFont.numeric(18))
                                        .frame(maxWidth: .infinity).frame(height: 48)
                                        .foregroundStyle(validatedGoal == preset ? Color.canvas : Color.primary)
                                        .background(validatedGoal == preset ? AccentChoice.current.color : Color.panel, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(validatedGoal == preset ? .isSelected : [])
                                .accessibilityIdentifier("goal_preset_\(preset)")
                            }
                        }
                    }
                    Slider(value: Binding(get: { sliderValue }, set: { value in
                        sliderValue = value.rounded()
                        draft = String(Int(value.rounded()))
                    }), in: 1...1000, step: 1, onEditingChanged: { editing in
                        if editing { inputFocused = false }
                    })
                    .tint(AccentChoice.current.color)
                    .accessibilityLabel(L.text("goal_slider"))
                    .accessibilityValue(String(Int(sliderValue)))
                    .accessibilityIdentifier("goal_slider")
                    Button(L.text("done")) { save() }
                        .buttonStyle(FilledButton())
                        .frame(maxWidth: 420).frame(maxWidth: .infinity)
                        .disabled(validatedGoal == nil)
                        .accessibilityIdentifier("goal_save")
                }
                }
            }
            .background(Color.canvas)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.text("cancel")) { dismiss() }.font(AppFont.text(15))
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L.text("done")) { inputFocused = false }.font(AppFont.text(15, weight: .medium))
                }
            }
        }
    }

    private func save() {
        guard let value = validatedGoal else { return }
        goal = value
        dismiss()
    }
}
