import SwiftUI
import AppKit

struct Quota: Codable, Identifiable {
    var label: String
    var used: Double
    var reset: Double?
    var id: String { label }
    var expired: Bool { reset.map { $0 < Date().timeIntervalSince1970 } ?? false }
}
struct Provider: Codable {
    var name: String
    var plan: String
    var windows: [Quota]
    var updated: Double?
    var message: String
    var stale: Bool { updated.map { Date().timeIntervalSince1970 - $0 > 900 } ?? false }
    var summary: String {
        guard !stale, let q = windows.max(by: { $0.used < $1.used }), !q.expired else { return "—" }
        return "\(Int(remainingQuota(q.used).rounded()))%"
    }
    static func empty(_ name: String) -> Provider { Provider(name: name, plan: "", windows: [], message: "正在读取额度…") }
}

func runScript(_ name: String, arguments: [String] = []) -> Data {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let root = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    process.arguments = [root.appendingPathComponent(name).path] + arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return Data() }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return data
}

@MainActor final class UsageStore: ObservableObject {
    @Published var codex = Provider.empty("Codex")
    @Published var claude = Provider.empty("Claude")
    @Published var accountLoading = false
    @Published var historyLoading = false
    @Published var request = HistoryRequest()
    @Published var displayedRequest:HistoryRequest?
    var loading:Bool { accountLoading || historyLoading }
    @Published var history: DailyHistory?
    @Published var historyError = ""
    @Published var connectionMessage = ""
    private let historyLoader:@Sendable ([String])->Data
    private var historyRequestedAgain = false
    init(historyLoader:@escaping @Sendable ([String])->Data = { runScript("history.py",arguments:$0) }) {
        self.historyLoader = historyLoader
    }
    func refresh() async {
        guard !accountLoading else { return }
        accountLoading = true
        async let c = Task.detached { runScript("usage.py") }.value
        async let a = Task.detached { runScript("usage.py", arguments: ["--claude"]) }.value
        let (cd, ad) = await (c, a)
        codex = decode(cd, name: "Codex")
        claude = decode(ad, name: "Claude")
        accountLoading = false
        await reloadHistory()
    }
    func chooseRange(_ next:HistoryRequest) async {
        request = next
        await reloadHistory()
    }
    func reloadHistory() async {
        guard !historyLoading else { historyRequestedAgain = true; return }
        historyLoading = true
        defer { historyLoading = false }
        // Serialize parsing while discarding stale responses after a newer selection.
        while true {
            historyRequestedAgain = false
            let target = request
            let loader = historyLoader
            let hd = await Task.detached { loader(target.arguments) }.value
            if target != request || historyRequestedAgain { continue }
            if let next = try? JSONDecoder().decode(DailyHistory.self, from:hd) {
                history = next
                displayedRequest = target
                historyError = ""
            } else { historyError = "读取失败，请重试或选择其他时间范围。" }
            return
        }
    }
    func decode(_ data: Data, name: String) -> Provider {
        (try? JSONDecoder().decode(Provider.self, from: data)) ?? Provider(name: name, plan: "", windows: [], message: "读取失败，请检查 Python 3 与 CLI 安装。")
    }
    func connect() async {
        connectionMessage = "正在连接…"
        let data = await Task.detached { runScript("connect.py") }.value
        connectionMessage = String(data: data, encoding: .utf8) ?? "连接失败"
    }
}

struct Dashboard: View {
    @ObservedObject var store: UsageStore
    @State private var showConnection = false
    var body: some View {
        VStack(spacing:12) {
            HistoryRangePicker(request:store.request) { next in Task { await store.chooseRange(next) } }
            if let history = store.history {
                ZStack {
                    HistoryPanel(history:history,loading:store.loading,onRefresh:{ Task { await store.refresh() } },onConnect:{
                        Task { await store.connect(); showConnection = true }
                    }).opacity(store.displayedRequest == store.request ? 1 : 0.25)
                        .allowsHitTesting(store.displayedRequest == store.request)
                    if store.displayedRequest != store.request {
                        VStack(spacing:12) {
                            if store.historyLoading { ProgressView().controlSize(.small) }
                            Text(store.historyLoading ? "正在读取所选时段…" : store.historyError).font(.system(size:12))
                            if !store.historyLoading { Button("重试") { Task { await store.reloadHistory() } } }
                        }.padding(16).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                    }
                }
                if !store.historyError.isEmpty {
                    Text("更新失败 · 显示上次记录").font(.system(size:11)).foregroundStyle(.orange)
                }
            } else {
                VStack(spacing:16) {
                    if store.loading { ProgressView().controlSize(.small) }
                    Text(store.historyError.isEmpty ? "正在读取剩余额度" : store.historyError).font(.system(size:13)).foregroundStyle(.secondary)
                    if !store.loading { Button("重试") { Task { await store.refresh() } } }
                    Button("退出") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).font(.system(size:11)).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity).frame(height:200)
            }
        }.padding(12).frame(width:360).background(Color(nsColor:.windowBackgroundColor))
            .alert("Claude Code",isPresented:$showConnection) { Button("好",role:.cancel) {} } message: { Text(store.connectionMessage) }
    }
}

@main struct UsageBarApp: App {
    @StateObject private var store = UsageStore()
    var body: some Scene {
        MenuBarExtra {
            Dashboard(store: store).environment(\.locale, Locale(identifier: "zh_CN"))
        } label: {
            Label("余 C \(store.codex.summary)" + (store.claude.windows.isEmpty ? "" : " · A \(store.claude.summary)"), systemImage: "chart.bar.xaxis")
                .task {
                    while !Task.isCancelled {
                        await store.refresh()
                        try? await Task.sleep(nanoseconds: 300_000_000_000)
                    }
                }
        }.menuBarExtraStyle(.window)
    }
}
