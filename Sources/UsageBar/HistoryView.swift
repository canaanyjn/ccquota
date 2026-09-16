import SwiftUI
import Charts

struct ModelTokens: Decodable, Identifiable {
    var model: String
    var provider: String
    var input: Double
    var cached: Double
    var output: Double
    var total: Double { input + cached + output }
    var id: String { provider + model }
}
struct TokenPoint: Decodable {
    var time: Double
    var start: Double
    var value: Double
    var cumulative: Double
    var models: [ModelTokens]
}
struct QuotaSample: Decodable, Identifiable, Equatable {
    var time: Double
    var provider: String
    var label: String
    var used: Double
    var reset: Double?
    var source: String
    var remaining: Double { remainingQuota(used) }
    var series: String { provider + " · " + label }
    var id: String { series + String(time) }
}
struct CycleSummary:Decodable {
    var series:String
    var provider:String
    var start:Double?
    var end:Double?
    var available:Bool
    var models:[ModelTokens]
    var total:Double
}
struct RangeSummary:Decodable {
    var provider:String
    var available:Bool
    var models:[ModelTokens]
    var total:Double
}
struct DailyHistory: Decodable {
    var start: Double
    var updated: Double
    var points: [TokenPoint]
    var quotas: [QuotaSample]
    var total: Double
    var requests: Int
    var cycles:[CycleSummary]? = nil
    var mode:String? = nil
    var rangeEnd:Double? = nil
    var interval:Double? = nil
    var rangeKey:String? = nil
    var summaries:[RangeSummary]? = nil
}
struct PlotSample: Identifiable, Equatable {
    var sample: QuotaSample
    var segment: Int
    var id: String { sample.id }
}
func quotaWindowTitle(_ label:String) -> String {
    var parts = label.components(separatedBy:" · ")
    if parts.first == "codex" { parts.removeFirst() }
    if let last = parts.last {
        parts[parts.count-1] = last == "7 天" ? "周额度" : last + "额度"
    }
    return parts.joined(separator:" · ").replacingOccurrences(of:"GPT-5.3-Codex-Spark",with:"Spark")
}

func compactTokens(_ value: Double) -> String {
    if value >= 1_000_000_000 { return String(format: "%.2fB", value / 1_000_000_000) }
    if value >= 1_000_000 { return String(format: "%.2fM", value / 1_000_000) }
    if value >= 1000 { return String(format: "%.1fK", value / 1000) }
    return String(format: "%.0f", value)
}

func remainingQuota(_ used: Double) -> Double { max(0, min(100, 100 - used)) }

func startsNewQuotaSegment(_ previous: QuotaSample, _ next: QuotaSample) -> Bool {
    if next.time - previous.time > 1800 { return true }
    if let before = previous.reset, let after = next.reset, abs(after - before) > 60 { return true }
    if let reset = previous.reset, previous.time < reset && next.time >= reset { return true }
    return false
}

func nearestQuotaSample(_ samples:[QuotaSample], to time:Double) -> QuotaSample? {
    guard !samples.isEmpty else { return nil }
    var low = 0, high = samples.count
    while low < high {
        let middle = (low + high) / 2
        if samples[middle].time < time { low = middle + 1 } else { high = middle }
    }
    if low == 0 { return samples[0] }
    if low == samples.count { return samples[low-1] }
    return time-samples[low-1].time <= samples[low].time-time ? samples[low-1] : samples[low]
}

func tokenPointAt(_ points:[TokenPoint],time:Double) -> TokenPoint? {
    var low = 0, high = points.count
    while low < high {
        let mid = (low+high)/2
        if points[mid].start <= time { low = mid+1 } else { high = mid }
    }
    guard low > 0 else { return nil }
    let point = points[low-1]
    return time < point.time || (low == points.count && time == point.time) ? point : nil
}

struct ModelBreakdownData {
    let point:TokenPoint
    let rows:[ModelTokens]
    let total:Double
}

// Construct once per incoming history snapshot, never once per mouse movement.
struct HistoryIndex {
    var keysByProvider:[String:[String]] = [:]
    var samplesBySeries:[String:[QuotaSample]] = [:]
    var plots:[String:[PlotSample]] = [:]
    var ranges:[String:ClosedRange<Double>] = [:]
    var breakdowns:[String:ModelBreakdownData] = [:]
    var cycles:[String:CycleSummary] = [:]
    var rangeSummaries:[String:RangeSummary] = [:]
    init(_ history:DailyHistory) {
        for cycle in history.cycles ?? [] { cycles[cycle.series] = cycle }
        for summary in history.summaries ?? [] { rangeSummaries[summary.provider] = summary }
        let relevant = history.quotas.filter { sample in
            guard history.mode == "cycle", let cycle = cycles[sample.series], cycle.available, let start = cycle.start else { return true }
            return sample.time >= start
        }
        let groups = Dictionary(grouping:relevant,by: \.series)
        for (key,unsorted) in groups {
            let samples = unsorted.sorted { $0.time < $1.time }
            samplesBySeries[key] = samples
            if let provider = samples.first?.provider { keysByProvider[provider,default:[]].append(key) }
            var segment = 0
            plots[key] = samples.enumerated().map { i,s in
                if i > 0 && startsNewQuotaSegment(samples[i-1],s) { segment += 1 }
                return PlotSample(sample:s,segment:segment)
            }
            let low = samples.map(\.remaining).min() ?? 0
            let high = samples.map(\.remaining).max() ?? 100
            let bottom = max(0,floor(low-1))
            let top = min(100,max(bottom+4,ceil(high+1)))
            ranges[key] = min(bottom,top-4)...top
            for sample in samples {
                if let point = tokenPointAt(history.points,time:sample.time) {
                    let rows = point.models.filter { $0.provider == sample.provider }
                    breakdowns[sample.id] = ModelBreakdownData(point:point,rows:rows,total:rows.reduce(0){$0+$1.total})
                }
            }
        }
        for cycle in cycles.values {
            if !(keysByProvider[cycle.provider] ?? []).contains(cycle.series) { keysByProvider[cycle.provider,default:[]].append(cycle.series) }
        }
        for provider in Array(keysByProvider.keys) { keysByProvider[provider]?.sort() }
    }
}

final class QuotaSelection: ObservableObject {
    @Published var time:Double?
    init(_ time:Double? = nil) { self.time = time }
    func update(_ next:Double?) {
        guard time != next else { return }
        var transaction = Transaction(animation:nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { time = next }
    }
    func endHover() { update(nil) }
}

struct HistoryPanel: View {
    let history: DailyHistory
    private let prepared: HistoryIndex
    var loading = false
    var onRefresh: () -> Void = {}
    var onConnect: () -> Void = {}
    @State private var provider = "Codex"
    @State private var chosenSeries = ""
    @StateObject private var selection:QuotaSelection
    private var selectedTime:Double? {
        get { selection.time }
        nonmutating set { selection.update(newValue) }
    }
    @State private var fullDay = false
    @State private var showInfo = false
    @Environment(\.colorScheme) private var scheme

    init(history: DailyHistory, loading: Bool = false, onRefresh: @escaping () -> Void = {}, onConnect: @escaping () -> Void = {}, selectedTime: Double? = nil) {
        self.history = history
        self.prepared = HistoryIndex(history)
        self.loading = loading
        self.onRefresh = onRefresh
        self.onConnect = onConnect
        _selection = StateObject(wrappedValue:QuotaSelection(selectedTime))
    }
    private var series: [String] { prepared.keysByProvider[provider] ?? [] }
    private var currentSeries: String { series.contains(chosenSeries) ? chosenSeries : (series.first(where: { $0.hasPrefix("Codex · codex ·") }) ?? series.first ?? "") }
    private var samples: [QuotaSample] { prepared.samplesBySeries[currentSeries] ?? [] }
    private var selected: QuotaSample? {
        guard let time = selectedTime else { return samples.last }
        return nearestQuotaSample(samples,to:time)
    }
    private var stale: Bool { selectedTime == nil && (samples.last.map { Date().timeIntervalSince1970 - $0.time > 900 || ($0.reset.map { $0 < Date().timeIntervalSince1970 } ?? false) } ?? false) }
    private var plot: [PlotSample] { prepared.plots[currentSeries] ?? [] }
    private var mode:String { history.mode ?? "cycle" }
    private var rangeEnd:Double { history.rangeEnd ?? history.updated }
    private var multiDay:Bool { !Calendar.current.isDate(Date(timeIntervalSince1970:history.start),inSameDayAs:Date(timeIntervalSince1970:rangeEnd)) }
    private var chartStart:Double {
        if mode == "cycle", let cycle = currentCycle, cycle.available, let start = cycle.start { return start }
        return mode != "today" || fullDay ? history.start : max(history.start,(samples.first?.time ?? history.start)-180)
    }
    private var yRange: ClosedRange<Double> { prepared.ranges[currentSeries] ?? 0...100 }
    private var breakdown: ModelBreakdownData? { selected.flatMap { prepared.breakdowns[$0.id] } }
    private var tokenPoint: TokenPoint? { breakdown?.point }
    private var currentCycle:CycleSummary? { prepared.cycles[currentSeries] }
    private var rangeSummary:RangeSummary? { prepared.rangeSummaries[provider] }
    private var summaryAvailable:Bool { mode == "cycle" ? currentCycle?.available == true : rangeSummary?.available == true }
    private var modelRows:[ModelTokens] {
        if selectedTime != nil { return breakdown?.rows ?? [] }
        return mode == "cycle" ? (currentCycle?.models ?? []) : (rangeSummary?.models ?? [])
    }
    private var total:Double {
        if selectedTime != nil { return breakdown?.total ?? 0 }
        return mode == "cycle" ? (currentCycle?.total ?? 0) : (rangeSummary?.total ?? 0)
    }
    private var scrollScope:String { (history.rangeKey ?? mode)+currentSeries+(selectedTime == nil ? ":summary" : ":period:\(tokenPoint?.start ?? 0)") }
    private var accent: Color { provider == "Codex" ? Color(red:0.82,green:0.29,blue:0.56) : Color(red:0.16,green:0.47,blue:0.88) }
    private var surface: Color { scheme == .dark ? Color(red:0.13,green:0.13,blue:0.15) : Color(red:0.955,green:0.953,blue:0.96) }
    private var ink: Color { scheme == .dark ? Color(red:0.92,green:0.91,blue:0.94) : Color(red:0.19,green:0.18,blue:0.23) }
    private var lineGradient: LinearGradient {
        LinearGradient(colors: provider == "Codex" ? [Color(red:0.51,green:0.32,blue:0.84),Color(red:0.91,green:0.40,blue:0.63)] : [Color(red:0.40,green:0.44,blue:0.84),Color(red:0.14,green:0.55,blue:0.94)],startPoint:.leading,endPoint:.trailing)
    }
    private var windowLabel: String { selected.map { quotaWindowTitle($0.label) } ?? "额度窗口" }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            VStack(alignment:.leading,spacing:18) {
                HStack(spacing:20) {
                    ForEach(["Codex","Claude"],id:\.self) { name in
                        Button {
                            provider = name; chosenSeries = ""; selectedTime = nil
                        } label: {
                            Text(name).font(.system(size:14,weight:provider == name ? .semibold : .regular))
                                .foregroundStyle(provider == name ? ink : ink.opacity(0.5))
                        }.buttonStyle(.plain).accessibilityAddTraits(provider == name ? [.isSelected] : [])
                    }
                    Spacer()
                    if !series.isEmpty {
                        Menu {
                            ForEach(series,id:\.self) { key in
                                Button(quotaWindowTitle(key.replacingOccurrences(of:provider + " · ",with:""))) { chosenSeries = key; selectedTime = nil }
                            }
                        } label: {
                            HStack(spacing:4) {
                                Text(windowLabel).lineLimit(1)
                                Image(systemName:"chevron.down").font(.system(size:8,weight:.semibold))
                            }.font(.system(size:11)).foregroundStyle(ink.opacity(0.55))
                        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("选择账户额度周期；上方日历控制查看时间范围")
                    }
                    moreMenu
                }
                if let s = selected {
                    HStack(alignment:.firstTextBaseline,spacing:6) {
                        Text(String(format:"%.0f",s.remaining)).font(.system(size:38,weight:.light,design:.rounded)).monospacedDigit()
                        Text("% ").font(.system(size:18,weight:.light))
                        Spacer()
                        VStack(alignment:.trailing,spacing:6) {
                            Text(selectedTime != nil ? "当时剩余" : mode == "custom" ? "末次剩余" : stale ? "上次剩余" : "剩余额度").font(.system(size:12,weight:.medium))
                            if selectedTime != nil || stale || mode == "custom" {
                                Text(Date(timeIntervalSince1970:s.time),format:multiDay ? .dateTime.month(.twoDigits).day(.twoDigits).hour().minute() : .dateTime.hour().minute()).font(.system(size:11)).foregroundStyle(ink.opacity(0.55))
                            } else if let reset = s.reset {
                                Text("\(Date(timeIntervalSince1970:reset),style:.relative)后重置").font(.system(size:11)).foregroundStyle(ink.opacity(0.55))
                            }
                        }
                    }.foregroundStyle(ink)
                    curve
                } else {
                    VStack(spacing:12) {
                        Text("—").font(.system(size:38,weight:.light))
                        Text(mode == "cycle" ? (provider == "Claude" ? "连接后开始记录剩余额度" : "等待额度数据") : "所选时段没有额度采样").font(.system(size:12)).foregroundStyle(.secondary)
                        if provider == "Claude" && mode == "cycle" { Button("连接 Claude Code",action:onConnect).buttonStyle(.plain).foregroundStyle(accent).font(.system(size:12,weight:.medium)) }
                    }.frame(maxWidth:.infinity).frame(height:180)
                }
            }.padding(20).background(surface,in:RoundedRectangle(cornerRadius:24))
            modelBreakdown.padding(.horizontal,8)
        }.foregroundStyle(ink)
        .onDisappear { selection.endHover() }
        .onChange(of:history.rangeKey) { _ in selection.endHover() }
        .popover(isPresented:$showInfo) {
            Text("曲线为账户剩余额度，按实际采样绘制。纵轴随数据缩放，刻度表示真实百分比。空缺超过 30 分钟或额度重置时断开。\n\n默认汇总所选时间范围内、本机同一平台的模型 token 数与占比（含缓存）。悬停查看对应时间片，移开恢复区间汇总。Token 占比不代表额度扣减比例。\n\n每 5 分钟刷新；Claude 随对话更新。")
                .font(.system(size:12)).lineSpacing(5).padding(20).frame(width:320)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("刷新",action:onRefresh).disabled(loading)
            Toggle("显示全天",isOn:$fullDay).disabled(mode != "today")
            Button("上一个节点") { moveSelection(-1) }.disabled(samples.isEmpty)
            Button("下一个节点") { moveSelection(1) }.disabled(samples.isEmpty)
            Button("查看区间汇总") { selectedTime = nil }
            Divider()
            Button("连接 / 更新 Claude Code",action:onConnect)
            Button("数据说明") { showInfo = true }
            Divider()
            Button("退出 UsageBar") { NSApplication.shared.terminate(nil) }
        } label: {
            Group {
                if loading { ProgressView().controlSize(.mini) }
                else { Image(systemName:"ellipsis").font(.system(size:16)) }
            }.frame(width:24,height:24).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多操作")
    }

    private var curve: some View {
        StaticQuotaChart(plot:plot,samples:samples,chartStart:chartStart,chartEnd:rangeEnd,yRange:yRange,provider:provider,appearance:provider+(scheme == .dark ? ":dark" : ":light"),accent:accent,ink:ink,lineGradient:lineGradient,selection:selection)
            .equatable().frame(height:145)
    }

    private var modelBreakdown: some View {
        VStack(alignment:.leading,spacing:12) {
            VStack(alignment:.leading,spacing:5) {
                HStack {
                    Text("模型用量").font(.system(size:14,weight:.semibold)).foregroundStyle(ink)
                    Spacer()
                    Text(selectedTime == nil && !summaryAvailable ? "— tokens" : compactTokens(total) + " tokens")
                        .monospacedDigit().help("本机已记录的输入、缓存读取与输出 token 总数")
                }
                HStack {
                    if selectedTime == nil && mode == "today" {
                        Text("今天 · \(Date(timeIntervalSince1970:history.start),format:.dateTime.month(.twoDigits).day(.twoDigits))")
                    } else if selectedTime == nil && mode != "cycle" {
                        Text("\(mode == "today" ? "今天" : mode == "week" ? "近 7 天" : "所选区间") · \(Date(timeIntervalSince1970:history.start),format:.dateTime.month(.twoDigits).day(.twoDigits))–\(Date(timeIntervalSince1970:rangeEnd),format:.dateTime.month(.twoDigits).day(.twoDigits))")
                    } else if selectedTime == nil {
                        if let cycle = currentCycle, cycle.available, let start = cycle.start, let end = cycle.end {
                            Text("本周期 · \(Date(timeIntervalSince1970:start),format:.dateTime.month(.twoDigits).day(.twoDigits))–\(Date(timeIntervalSince1970:end),format:.dateTime.month(.twoDigits).day(.twoDigits))")
                                .help("周期开始：\(Date(timeIntervalSince1970:start).formatted())；周期结束：\(Date(timeIntervalSince1970:end).formatted())")
                        } else { Text("周期信息待更新") }
                    } else if let p = tokenPoint {
                        Text("\(Date(timeIntervalSince1970:p.start),format:multiDay ? .dateTime.month(.twoDigits).day(.twoDigits).hour().minute() : .dateTime.hour().minute())–\(Date(timeIntervalSince1970:p.time),format:.dateTime.hour().minute())")
                    } else { Text("选中时段") }
                    Spacer()
                    Text("本机记录")
                }
            }.font(.system(size:11)).foregroundStyle(ink.opacity(0.55))
            Group {
                if modelRows.isEmpty {
                    Text(selectedTime == nil ? (summaryAvailable ? "所选区间没有模型记录" : "没有可读取的统计记录") : "这段时间没有模型记录").font(.system(size:12)).foregroundStyle(.secondary)
                        .frame(maxWidth:.infinity,alignment:.leading)
                } else {
                    ScrollViewReader { scroll in
                        ScrollView {
                            VStack(spacing:12) {
                                ForEach(modelRows) { row in
                                    HStack(spacing:8) {
                                        Circle().fill(modelColor(row.model)).frame(width:5,height:5)
                                        Text(row.model).font(.system(size:12)).lineLimit(1)
                                        Spacer()
                                        Text(compactTokens(row.total)).font(.system(size:11)).foregroundStyle(ink.opacity(0.6)).monospacedDigit().frame(width:58,alignment:.trailing)
                                        Text(String(format:"%.1f%%",row.total / max(1,total) * 100)).font(.system(size:12,weight:.medium)).monospacedDigit().frame(width:45,alignment:.trailing)
                                    }.help("\(row.model) · \(Int(row.total).formatted()) tokens · 输入 \(compactTokens(row.input)) · 缓存 \(compactTokens(row.cached)) · 输出 \(compactTokens(row.output))")
                                }
                            }.id("model-start")
                        }.onChange(of:scrollScope) { _ in
                            scroll.scrollTo("model-start",anchor:.top)
                        }
                    }
                }
            }.frame(height:112,alignment:.topLeading)
        }.frame(height:164,alignment:.top)
    }
    private func modelColor(_ name:String) -> Color {
        let colors:[Color] = [accent,Color(red:0.46,green:0.38,blue:0.78),Color(red:0.24,green:0.53,blue:0.77)]
        return colors[name.utf8.reduce(0) { ($0 + Int($1)) % colors.count }]
    }
    private func moveSelection(_ delta:Int) {
        guard let s = selected, let index = samples.firstIndex(where: { $0.id == s.id }) else { return }
        selectedTime = samples[max(0,min(samples.count-1,index+delta))].time
    }
}

// Always include the first observation; keep regular ticks far enough away to stay legible.
func quotaTimeTicks(start:Double,end:Double,firstSample:Double?) -> [Date] {
    guard end > start else { return [Date(timeIntervalSince1970:start)] }
    let span = end-start
    let interval = [60.0,300,600,900,1800,3600,7200,10800,21600,43200,86400].first { span / $0 <= 4 } ?? ceil(span/4/86400)*86400
    let first = firstSample.flatMap { $0 >= start && $0 <= end ? $0 : nil } ?? start
    var ticks = [first]
    var next = ceil(start/interval)*interval
    while next <= end {
        if ticks.allSatisfy({ abs($0-next) >= span/5 }) { ticks.append(next) }
        next += interval
    }
    return ticks.sorted().map { Date(timeIntervalSince1970:$0) }
}

// Selection lives in the overlay; moving it does not rebuild axes, samples or the curve.
struct StaticQuotaChart: View, Equatable {
    let plot:[PlotSample]
    let samples:[QuotaSample]
    let chartStart:Double
    let chartEnd:Double
    let yRange:ClosedRange<Double>
    let provider:String
    let appearance:String
    let accent:Color
    let ink:Color
    let lineGradient:LinearGradient
    let selection:QuotaSelection
    static func == (lhs:Self,rhs:Self) -> Bool {
        lhs.plot == rhs.plot && lhs.chartStart == rhs.chartStart && lhs.chartEnd == rhs.chartEnd && lhs.yRange == rhs.yRange && lhs.appearance == rhs.appearance && lhs.selection === rhs.selection
    }
    var body: some View {
        Chart {
            ForEach(plot) { p in
                // Invisible hit metadata preserves every observation for accessibility.
                PointMark(x:.value("时间",Date(timeIntervalSince1970:p.sample.time)),y:.value("剩余 %",p.sample.remaining)).foregroundStyle(accent.opacity(0)).symbolSize(1)
            }
        }
        .chartYScale(domain:yRange)
        .chartXScale(domain:Date(timeIntervalSince1970:chartStart)...Date(timeIntervalSince1970:max(chartStart+1,chartEnd)))
        .chartYAxis {
            AxisMarks(values:[yRange.lowerBound,yRange.upperBound]) { value in
                AxisValueLabel { if let n = value.as(Double.self) { Text("\(Int(n))%").font(.system(size:10)).foregroundStyle(ink.opacity(0.5)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values:quotaTimeTicks(start:chartStart,end:max(chartStart+1,chartEnd),firstSample:samples.first?.time)) { value in
                AxisGridLine(stroke:StrokeStyle(lineWidth:1)).foregroundStyle(ink.opacity(0.045))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        VStack(spacing:2) {
                            if chartEnd-chartStart > 86400 {
                                Text(date,format:.dateTime.month(.twoDigits).day(.twoDigits))
                                if chartEnd-chartStart < 3*86400 { Text(date,format:.dateTime.hour().minute()) }
                            } else { Text(date,format:.dateTime.hour().minute()) }
                        }.font(.system(size:10)).foregroundStyle(ink.opacity(0.5)).fixedSize()
                    }
                }
            }
        }
        .chartBackground { proxy in
            GeometryReader { geo in
                roundedCurve(proxy:proxy,geo:geo)
                    .stroke(lineGradient,style:StrokeStyle(lineWidth:2.5,lineCap:.round,lineJoin:.round))
                    .allowsHitTesting(false)
            }
        }
        .chartOverlay { proxy in
            ChartCursorOverlay(samples:samples,proxy:proxy,accent:accent,selection:selection)
        }
        .accessibilityLabel("\(provider)剩余额度历史曲线，\(samples.count) 个采样点。可从更多菜单逐个选择节点。")
    }
    // Round corners in display space only. Raw samples, selection and gap boundaries stay intact.
    private func roundedCurve(proxy:ChartProxy,geo:GeometryProxy) -> Path {
        let origin = geo[proxy.plotAreaFrame].origin
        let groups = Dictionary(grouping:plot,by: \.segment)
        var path = Path()
        for key in groups.keys.sorted() {
            let points = (groups[key] ?? []).compactMap { item -> CGPoint? in
                guard let x = proxy.position(forX:Date(timeIntervalSince1970:item.sample.time)),
                      let y = proxy.position(forY:item.sample.remaining) else { return nil }
                return CGPoint(x:origin.x+x,y:origin.y+y)
            }.reduce(into:[CGPoint]()) { result, point in
                if result.last.map({ hypot($0.x-point.x,$0.y-point.y) > 0.01 }) ?? true { result.append(point) }
            }
            guard let first = points.first else { continue }
            if points.count == 1 {
                path.addEllipse(in:CGRect(x:first.x-0.75,y:first.y-0.75,width:1.5,height:1.5))
                continue
            }
            path.move(to:first)
            if points.count > 2 {
                for i in 1..<(points.count-1) {
                    let previous = points[i-1], corner = points[i], next = points[i+1]
                    let incoming = hypot(corner.x-previous.x,corner.y-previous.y)
                    let outgoing = hypot(next.x-corner.x,next.y-corner.y)
                    let radius = min(14,min(incoming,outgoing)*0.45)
                    let entry = CGPoint(x:corner.x+(previous.x-corner.x)*radius/incoming,y:corner.y+(previous.y-corner.y)*radius/incoming)
                    let exit = CGPoint(x:corner.x+(next.x-corner.x)*radius/outgoing,y:corner.y+(next.y-corner.y)*radius/outgoing)
                    path.addLine(to:entry)
                    path.addQuadCurve(to:exit,control:corner)
                }
            }
            if let last = points.last { path.addLine(to:last) }
        }
        return path
    }

}

struct ChartCursorOverlay: View {
    let samples:[QuotaSample]
    let proxy:ChartProxy
    let accent:Color
    @ObservedObject var selection:QuotaSelection
    private var selectedTime:Double? {
        get { selection.time }
        nonmutating set { selection.update(newValue) }
    }
    var body: some View {
        GeometryReader { geo in
            let origin = geo[proxy.plotAreaFrame].origin
            let sample = selectedTime.flatMap { nearestQuotaSample(samples,to:$0) } ?? samples.last
            ZStack(alignment:.topLeading) {
                if let sample = sample, let x = proxy.position(forX:Date(timeIntervalSince1970:sample.time)), let y = proxy.position(forY:sample.remaining) {
                    if selectedTime != nil {
                        Path { path in
                            path.move(to:CGPoint(x:origin.x+x,y:origin.y))
                            path.addLine(to:CGPoint(x:origin.x+x,y:geo[proxy.plotAreaFrame].maxY))
                        }.stroke(accent.opacity(0.14),lineWidth:1).allowsHitTesting(false)
                    }
                    ZStack {
                        Circle().fill(accent.opacity(0.10)).frame(width:22,height:22)
                        Circle().fill(accent.opacity(0.16)).frame(width:14,height:14)
                        Circle().fill(accent).frame(width:6,height:6)
                    }.position(x:origin.x+x,y:origin.y+y).allowsHitTesting(false)
                }
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): select(location,geo:geo)
                        case .ended: selection.endHover()
                        }
                    }
                    .gesture(DragGesture(minimumDistance:0).onChanged { select($0.location,geo:geo) })
            }
        }
    }
    private func select(_ location:CGPoint,geo:GeometryProxy) {
        let frame = geo[proxy.plotAreaFrame]
        guard frame.contains(location) else { selection.endHover(); return }
        guard let date:Date = proxy.value(atX:location.x-frame.origin.x),
              let sample = nearestQuotaSample(samples,to:date.timeIntervalSince1970) else { return }
        selection.update(sample.time)
    }
}
