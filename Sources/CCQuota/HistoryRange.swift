import SwiftUI

struct HistoryRequest:Equatable,Hashable {
    var mode:String = "cycle"
    var start:Double? = nil
    var end:Double? = nil
    var arguments:[String] {
        var args = ["--mode",mode]
        if let start = start { args += ["--start",String(start)] }
        if let end = end { args += ["--end",String(end)] }
        return args
    }
    var title:String {
        switch mode {
        case "today": return "今天"
        case "week": return "近 7 天"
        case "custom": return "自定义范围"
        default: return "当前周期"
        }
    }
}

struct HistoryRangePicker:View {
    let request:HistoryRequest
    var onSelect:(HistoryRequest)->Void
    @State private var editing = false
    @State private var draftStart = Calendar.current.date(byAdding:.day,value:-6,to:Date()) ?? Date()
    @State private var draftEnd = Date()
    var body:some View {
        HStack {
            Menu {
                Button("当前周期") { onSelect(HistoryRequest()) }
                Button("今天") { onSelect(HistoryRequest(mode:"today")) }
                Button("近 7 天") { onSelect(HistoryRequest(mode:"week")) }
                Divider()
                Button("自定义范围…") {
                    draftStart = request.start.map(Date.init(timeIntervalSince1970:)) ?? Calendar.current.startOfDay(for:Calendar.current.date(byAdding:.day,value:-6,to:Date()) ?? Date())
                    draftEnd = request.end.map(Date.init(timeIntervalSince1970:)) ?? Date()
                    editing = true
                }
            } label: {
                Label(request.title,systemImage:"calendar").font(.system(size:12,weight:.medium))
            }.menuStyle(.borderlessButton).fixedSize()
            Spacer()
            if let start = request.start, let end = request.end {
                Group {
                    if Calendar.current.isDate(Date(timeIntervalSince1970:start),inSameDayAs:Date(timeIntervalSince1970:end)) {
                        Text("\(Date(timeIntervalSince1970:start),format:.dateTime.month(.twoDigits).day(.twoDigits)) · \(Date(timeIntervalSince1970:start),format:.dateTime.hour().minute())–\(Date(timeIntervalSince1970:end),format:.dateTime.hour().minute())")
                    } else {
                        Text("\(Date(timeIntervalSince1970:start),format:.dateTime.month(.twoDigits).day(.twoDigits))–\(Date(timeIntervalSince1970:end),format:.dateTime.month(.twoDigits).day(.twoDigits))")
                    }
                }.font(.system(size:10)).foregroundStyle(.secondary)
                    .help("\(Date(timeIntervalSince1970:start).formatted()) 至 \(Date(timeIntervalSince1970:end).formatted())")
            }
        }.padding(.horizontal,8)
        .popover(isPresented:$editing) {
            HistoryRangeForm(start:$draftStart,end:$draftEnd,onCancel:{ editing = false },onApply:{ next in
                onSelect(next)
                editing = false
            })
        }
    }
}

func minuteBoundary(_ date:Date) -> Date {
    Calendar.current.dateInterval(of:.minute,for:date)?.start ?? date
}

struct HistoryRangeForm:View {
    @Binding var start:Date
    @Binding var end:Date
    var onCancel:()->Void
    var onApply:(HistoryRequest)->Void
    private var valid:Bool { minuteBoundary(start) < minuteBoundary(end) && start < Date() }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("选择时间范围").font(.system(size:15,weight:.semibold))
            DatePicker("开始",selection:$start,in:...Date(),displayedComponents:[.date,.hourAndMinute])
            DatePicker("结束",selection:$end,in:...Date(),displayedComponents:[.date,.hourAndMinute])
            if !valid { Text("开始时间需早于结束时间").font(.system(size:11)).foregroundStyle(.red) }
            HStack {
                Button("取消",action:onCancel)
                Spacer()
                Button("应用") {
                    onApply(HistoryRequest(mode:"custom",start:minuteBoundary(start).timeIntervalSince1970,end:minuteBoundary(end).timeIntervalSince1970))
                }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(20).frame(width:320)
    }
}
