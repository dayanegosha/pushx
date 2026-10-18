import SwiftUI
import Charts
import UniformTypeIdentifiers

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? "" }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

struct HistoryView: View {
    @EnvironmentObject private var store: WorkoutStore
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var subscription: SubscriptionService
    @State private var showPlus = false
    @State private var export = false
    @State private var document = CSVDocument(text: "")
    @State private var exportError = false
    private var records: [WorkoutRecord] { store.visible(for: auth.session?.userID) }
    private var days: [(date: Date, reps: Int)] {
        (0..<7).reversed().map { offset in
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: .now)!
            return (date, records.filter { Calendar.current.isDate($0.endedAt, inSameDayAs: date) }.reduce(0) { $0 + $1.repetitions })
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                AdaptiveContent(maxWidth: 760) {
                VStack(alignment: .leading, spacing: 24) {
                    PageTitle(title: L.text("history"))
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .firstTextBaseline) { Text(L.text("last_7_days")).font(AppFont.text(15, weight: .medium)).fixedSize(horizontal: false, vertical: true); Spacer(); Text("\(days.reduce(0) { $0 + $1.reps })").font(AppFont.numeric(24)).fixedSize() }
                        Chart(days, id: \.date) { day in
                            BarMark(x: .value("day", day.date, unit: .day), y: .value("reps", day.reps))
                                .foregroundStyle(Color.primary).cornerRadius(3)
                        }
                        .chartYScale(domain: 0...max(10, days.map(\.reps).max() ?? 10))
                        .chartYAxis(.hidden)
                        .chartXAxis { AxisMarks(values: .stride(by: .day)) { value in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                        .frame(height: 140)
                    }.padding(22).background(Color.panel, in: RoundedRectangle(cornerRadius: 26))
                    if subscription.isPremium {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            metric(L.text("avg_set"), value: records.isEmpty ? "0" : String(records.reduce(0) { $0 + $1.repetitions } / records.count))
                            metric(L.text("active_days"), value: String(Set(records.map { Calendar.current.startOfDay(for: $0.endedAt) }).count))
                            metric(L.text("total_time"), value: "\(Int(records.reduce(0) { $0 + $1.duration } / 60)) \(L.text("min"))")
                        }
                        Button { document = CSVDocument(text: store.csv(for: auth.session?.userID)); export = true } label: { Label(L.text("export_csv"), systemImage: "square.and.arrow.up") }.font(AppFont.text(15, weight: .medium))
                    } else {
                        Button { showPlus = true } label: {
                            HStack { Image(systemName: "plus.circle"); Text(L.text("plus_analytics")); Spacer(); Image(systemName: "arrow.up.right") }.font(AppFont.text(13, weight: .medium)).padding(20).background(Color.panel, in: RoundedRectangle(cornerRadius: 20))
                        }.buttonStyle(.plain)
                    }
                    HStack { Text(L.text("your_workouts")).font(AppFont.text(17, weight: .semibold)).fixedSize(horizontal: false, vertical: true); Spacer(); if model.syncing { ProgressView().scaleEffect(0.7) } }
                    if records.isEmpty {
                        InfoCard(icon: "clock", title: L.text("history_empty"), detail: L.text("history_empty_body"))
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(records) { item in
                                HStack(alignment: .top, spacing: 14) {
                                    Image(systemName: item.detectionMode == "camera" ? "viewfinder" : "hand.tap").font(.title3).frame(width: 40, height: 46).background(Color.canvas, in: RoundedRectangle(cornerRadius: 12))
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(item.endedAt.formatted(.dateTime.locale(Locale(identifier: L.language)).day().month().hour().minute())).font(AppFont.text(13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                                        HStack(alignment: .top, spacing: 7) {
                                            Text(WorkoutView.elapsed(item.duration))
                                            Text("·")
                                            Text(L.text(item.detectionMode == "camera" ? "camera_mode" : "touch_mode"))
                                            if item.healthSynced { Image(systemName: "heart.fill").accessibilityLabel(L.text("health_saved")) }
                                            if item.cloudSynced { Image(systemName: "icloud").accessibilityLabel(L.text("cloud_saved")) }
                                        }.font(AppFont.text(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Spacer()
                                    Text("\(item.repetitions)").font(AppFont.numeric(28)).monospacedDigit().fixedSize()
                                }.padding(16).background(Color.panel, in: RoundedRectangle(cornerRadius: 22))
                            }
                        }
                    }
                    if let error = model.syncError { StatusNote(text: error) }
                    if let error = model.healthError { StatusNote(text: error) }
                    Button(L.text("sync_now")) { Task { await model.synchronize() } }.font(AppFont.text(13)).disabled(model.syncing)
                }
                }
            }.background(Color.canvas).toolbar(.hidden, for: .navigationBar).refreshable { await model.synchronize() }
                .sheet(isPresented: $showPlus) { PlusView().adaptiveSheet() }
                .fileExporter(isPresented: $export, document: document, contentType: .commaSeparatedText, defaultFilename: "forma-workouts") { result in if case .failure = result { exportError = true } }
                .alert(L.text("export_error"), isPresented: $exportError) { Button(L.text("done"), role: .cancel) {} }
        }
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(value).font(AppFont.text(21, weight: .semibold)); Text(title).font(AppFont.text(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(Color.panel, in: RoundedRectangle(cornerRadius: 18))
    }
}
