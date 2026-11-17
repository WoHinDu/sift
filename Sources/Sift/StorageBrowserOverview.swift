import SwiftUI

struct StorageCapacityPresentation: Equatable {
    let free: Int64?
    let capacity: Int64?
    var isValid: Bool {
        guard let free, let capacity else { return false }
        return capacity > 0 && free >= 0 && free <= capacity
    }
    var used: Int64? { isValid ? capacity! - free! : nil }
    var freeFraction: Double? { isValid ? Double(free!) / Double(capacity!) : nil }
    var lowSpace: Bool { (freeFraction ?? 1) < 0.05 }
}

struct StorageCapacityOverview: View {
    let values: StorageCapacityPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(values.isValid ? ByteFormatting.string(values.free!) : "Unavailable")
                    .font(.system(size: 27, weight: .semibold)).tracking(-0.6).monospacedDigit()
                if values.isValid { Text("available").font(.callout).foregroundStyle(SiftChartStyle.secondaryText) }
                Spacer(minLength: 4)
                Text(values.lowSpace ? "Low space" : "Mac storage")
                    .font(.caption2).foregroundStyle(values.lowSpace ? SiftChartStyle.accent : SiftChartStyle.mutedText)
            }
            if let freeFraction = values.freeFraction, let used = values.used, let capacity = values.capacity {
                Canvas { context, size in
                    let cells = 48, gap: CGFloat = 2
                    let width = max(0, (size.width - CGFloat(cells - 1) * gap) / CGFloat(cells))
                    for index in 0..<cells {
                        let fraction = Double(index) / Double(cells)
                        let color = fraction < 1 - freeFraction ? SiftChartStyle.secondaryText.opacity(0.4) : SiftChartStyle.inventoryColor(for: "worktrees")
                        let rect = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: size.height)
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
                    }
                }.frame(height: 9).accessibilityHidden(true)
                HStack {
                    Text("\(ByteFormatting.string(used)) used")
                    Spacer()
                    Text("\(ByteFormatting.string(capacity)) total")
                }.font(.caption2.monospacedDigit()).foregroundStyle(SiftChartStyle.secondaryText)
            } else {
                Text("macOS hasn’t reported disk capacity yet.").font(.caption).foregroundStyle(SiftChartStyle.secondaryText)
            }
        }.padding(12).siftStorageSurface()
            .accessibilityElement(children: .combine)
    }
}

enum StorageBrowserStatus: Equatable {
    case unscanned, scanning, stopping, queued(Int), cancelled, timedOut, limited, privacyScoped, cached, ready

    static func resolve(measurement: StorageMeasurement?, scanning: Bool, queuePosition: Int?, stopping: Bool) -> Self {
        if stopping { return .stopping }
        if let queuePosition { return .queued(queuePosition) }
        if scanning { return .scanning }
        guard let measurement else { return .unscanned }
        if measurement.cancelled == true { return .cancelled }
        if measurement.timedOut { return .timedOut }
        if measurement.limitedAccess || !measurement.isComplete { return .limited }
        if measurement.privacyExcluded == true { return .privacyScoped }
        if measurement.cached == true { return .cached }
        return .ready
    }
    var title: String {
        switch self {
        case .unscanned: return "Not scanned"
        case .scanning: return "Scanning · partial results"
        case .stopping: return "Stopping scan…"
        case let .queued(position): return "Queued · \(position) in line"
        case .cancelled: return "Scan cancelled · partial results"
        case .timedOut: return "Scan timed out · partial results"
        case .limited: return "Some folders couldn’t be read"
        case .privacyScoped: return "Privacy-protected folders skipped"
        case .cached: return "Validated saved results"
        case .ready: return "Scan complete"
        }
    }
    var needsAttention: Bool {
        switch self { case .cancelled, .timedOut, .limited: true; default: false }
    }
}

struct StorageLocation: Identifiable, Equatable {
    var id: String { path }
    let name: String
    let symbol: String
    let path: String
    static func shortcuts(home: String = NSHomeDirectory()) -> [Self] {
        [.init(name: "Home", symbol: "house", path: home),
         .init(name: "App data", symbol: "square.grid.2x2", path: home + "/Library"),
         .init(name: "Data volume", symbol: "internaldrive", path: StorageOverviewService.rootPath)]
    }
    static func selected(for path: String, home: String = NSHomeDirectory()) -> String {
        if StorageExplorerResults.contains(home + "/Library", path) { return home + "/Library" }
        if StorageExplorerResults.contains(home, path) { return home }
        return StorageOverviewService.rootPath
    }
}

struct StorageLocationShortcuts: View {
    @Binding var path: String
    var body: some View {
        HStack(spacing: 6) {
            ForEach(StorageLocation.shortcuts()) { location in
                let selected = StorageLocation.selected(for: path) == location.path
                Button { path = location.path } label: {
                    HStack(spacing: 6) {
                        Image(systemName: location.symbol)
                        Text(location.name)
                    }.font(.caption.weight(selected ? .semibold : .regular))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .foregroundStyle(selected ? Color.primary : SiftChartStyle.secondaryText)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .help("Browse \(location.path). Scanning starts only when you choose Scan.")
            }
        }
    }
}

struct StorageScanButton: View {
    let title: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        styled.controlSize(.small).buttonBorderShape(.capsule).disabled(disabled)
    }
    private var button: some View { Button(title, action: action).font(.caption.weight(.semibold)) }
    @ViewBuilder private var styled: some View {
        if #available(macOS 26, *) { button.buttonStyle(.glassProminent).tint(SiftChartStyle.accent) }
        else { button.buttonStyle(.borderedProminent).tint(SiftChartStyle.accent) }
    }
}
