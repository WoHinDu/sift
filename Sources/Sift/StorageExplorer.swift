import AppKit
import Foundation
import SwiftUI

enum StorageExplorerSort: String, CaseIterable {
    case size = "Largest first", growth = "Most growth", name = "Name"
}

enum StorageExplorerResults {
    static let fileLimit = StorageFile.sampleLimit

    static func folders(_ measurement: StorageMeasurement, query: String, sort: StorageExplorerSort,
                        baseline: StorageMeasurement?) -> [StorageFolder] {
        let previous = Dictionary((baseline?.folders ?? []).map { ($0.path, $0.bytes) }, uniquingKeysWith: { _, new in new })
        let canCompare = measurement.isComplete && !measurement.limitedAccess && baseline?.isComplete == true &&
            baseline?.limitedAccess == false && baseline.map { measurement.comparable(to: $0) } == true
        return measurement.folders.filter { matches($0.path, query: query) }.sorted {
            if sort == .name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if sort == .growth, canCompare {
                let a = $0.bytes - (previous[$0.path] ?? 0), b = $1.bytes - (previous[$1.path] ?? 0)
                if a != b { return a > b }
            }
            return $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes
        }
    }

    static func files(_ measurement: StorageMeasurement, query: String, sort: StorageExplorerSort) -> [StorageFile] {
        (measurement.largeFiles ?? []).filter { matches($0.path, query: query) }.sorted {
            if sort == .name { return $0.name == $1.name ? $0.path < $1.path : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes
        }
    }

    static func matches(_ path: String, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { path.localizedStandardContains(String($0)) }
    }

    /// Lexical normalization only: classification must not follow an arbitrary
    /// symlink and accidentally present an unknown path as a cleanup target.
    static func canonical(_ path: String) -> String {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = StorageOverviewService.rootPath
        if path == root { return "/" }
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count)) : path
    }

    static func contains(_ root: String, _ path: String) -> Bool {
        let root = canonical(root), path = canonical(path)
        return root == path || (root == "/" ? path.hasPrefix("/") : path.hasPrefix(root + "/"))
    }

    static func breadcrumbs(_ path: String) -> [StorageBreadcrumb] {
        let root = StorageOverviewService.rootPath
        guard path != root, path != "/" else { return [.init(path: root, name: "Data")] }
        let components = canonical(path).split(separator: "/")
        let dataPrefix = path.hasPrefix(root + "/") ? root : ""
        var result = [StorageBreadcrumb(path: root, name: "Data")]
        var ancestor = dataPrefix
        for component in components {
            ancestor += "/" + component
            result.append(.init(path: ancestor, name: String(component)))
        }
        return result
    }

    static func fraction(bytes: Int64, maximum: Int64) -> Double {
        guard maximum > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / Double(maximum)))
    }
}

struct StorageBreadcrumb: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
}

struct StorageCleanupTarget: Equatable {
    enum Kind: Equatable { case cache(String), workspace(String) }
    let kind: Kind
    let name: String
    let path: String
    var scopeDescription: String {
        switch kind {
        case .cache: return "Review covers the complete supported cache, not just this row."
        case .workspace: return "Review covers generated folders only; source files and project roots stay protected."
        }
    }
}

struct StoragePathContext {
    let label: String
    let target: StorageCleanupTarget?
    var color: Color {
        switch label {
        case "Known cache": return SiftChartStyle.inventoryColor(for: CacheCategory.packages.id)
        case "Generated data", "Project · generated folders": return SiftChartStyle.inventoryColor(for: "worktrees")
        case "Personal data": return SiftChartStyle.inventoryColor(for: CacheCategory.apps.id)
        default: return SiftChartStyle.mutedText
        }
    }

    static func classify(_ path: String, caches: [GlobalCache], workspaces: [Workspace], home: String = NSHomeDirectory()) -> Self {
        // Only current, explicitly supported cleanup targets get a handoff.
        // A folder called 'cache' or 'node_modules' alone is not authorization.
        let cache = caches.filter { cache in
            cache.state.path.map { StorageExplorerResults.contains($0, path) } ?? false
        }.max { ($0.state.path?.count ?? 0) < ($1.state.path?.count ?? 0) }
        if let cache, let cachePath = cache.state.path {
            return Self(label: "Known cache", target: StorageCleanupTarget(kind: .cache(cache.id), name: cache.name, path: cachePath))
        }
        if let workspace = workspaces.first(where: { workspace in
            StorageExplorerResults.canonical(workspace.url.path) == StorageExplorerResults.canonical(path) ||
                workspace.candidates.contains { StorageExplorerResults.contains($0.url.path, path) }
        }), !workspace.candidates.isEmpty {
            let isRoot = StorageExplorerResults.canonical(workspace.url.path) == StorageExplorerResults.canonical(path)
            return Self(label: isRoot ? "Project · generated folders" : "Generated data", target: StorageCleanupTarget(kind: .workspace(workspace.id), name: workspace.name, path: workspace.url.path))
        }
        let personal = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]
            .contains { StorageExplorerResults.contains(home + "/" + $0, path) }
        return Self(label: personal ? "Personal data" : "Needs review", target: nil)
    }
}


struct StorageExplorerView: View {
    @ObservedObject var overview: StorageOverviewModel
    @EnvironmentObject private var app: AppModel
    var onReviewCleanup: (StorageCleanupTarget) -> Void = { _ in }
    @State private var query = ""
    @State private var filesMode = false
    @State private var sort: StorageExplorerSort = .size
    @State private var confirmProtectedScan = false
    @State private var protectedScanPath: String?
    @State private var protectedFullRescan = false
    var showsCapacity = true
    init(overview: StorageOverviewModel, onReviewCleanup: @escaping (StorageCleanupTarget) -> Void = { _ in }, showingFiles: Bool = false, showsCapacity: Bool = true) {
        self.overview = overview
        self.onReviewCleanup = onReviewCleanup
        _filesMode = State(initialValue: showingFiles)
        self.showsCapacity = showsCapacity
    }
    private var path: String { overview.location }
    private var busy: Bool { overview.scanningPaths.contains(path) || overview.queuedPaths.contains(path) }
    private var measurement: StorageMeasurement? {
        overview.progress[path]?.displaying(over: overview.measurements[path]) ?? overview.partialMeasurements[path] ?? overview.measurements[path]
    }
    private var baseline: StorageMeasurement? { overview.growthBaseline(for: path) }

    private var scanState: StorageBrowserStatus {
        StorageBrowserStatus.resolve(measurement: measurement, scanning: overview.scanningPaths.contains(path),
            queuePosition: overview.queuedPaths.firstIndex(of: path).map { $0 + 1 },
            stopping: overview.cancellingPaths.contains(path))
    }
    private var folderName: String { StorageFolder(path: path, bytes: 0).name }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsCapacity {
                StorageCapacityOverview(values: StorageCapacityPresentation(free: app.freeDiskSpace(), capacity: app.diskCapacity()))
            }
            StorageLocationShortcuts(path: $overview.location)
            VStack(alignment: .leading, spacing: 7) {
                explorerHeader
                if path != StorageOverviewService.rootPath { breadcrumbs }
                scanStatus
                if let error = overview.errors[path], measurement?.cancelled != true {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption2).foregroundStyle(.orange).lineLimit(3).help(error)
                }
                if let measurement {
                    results(measurement)
                } else {
                    unscannedState
                }
            }
            DisclosureGroup("About these sizes & access") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Read-only exploration. Sizes describe stored data, not guaranteed cleanup savings. Files and folders may share APFS blocks.")
                    Text("Scans start only when you ask and continue when this menu closes. macOS may request access; denying it leaves partial results.")
                    Text("Broad scans skip known privacy-protected folders, including media libraries, personal folders, cloud files, and app containers. To measure one, open it and explicitly confirm a scan; macOS may then request access.")
                    Text("Largest files shows up to 100 regular files encountered in this location and its subfolders. File sizes overlap folder totals; filters search this sample, not the whole disk.")
                    if let measurement { accounting(measurement) }
                }.font(.caption2).foregroundStyle(SiftChartStyle.secondaryText).padding(.top, 7)
            }.font(.caption).foregroundStyle(SiftChartStyle.secondaryText)
        }
        .onChange(of: path) { _, newPath in
            query = ""; filesMode = false
            if protectedScanPath != newPath { confirmProtectedScan = false; protectedScanPath = nil }
        }
        .confirmationDialog("Scan this protected location?", isPresented: $confirmProtectedScan, titleVisibility: .visible) {
            Button("Scan this location") {
                if let target = protectedScanPath {
                    overview.scan(target, force: true, fullRescan: protectedFullRescan, discoverFiles: true)
                }
                protectedScanPath = nil
            }
            Button("Cancel", role: .cancel) { protectedScanPath = nil }
        } message: {
            Text("This folder is excluded from broad scans for privacy. Scanning it may cause macOS to ask for access. No files will be changed.")
        }
    }

    private var unscannedState: some View {
        VStack(spacing: 9) {
            Image(systemName: busy ? "folder.badge.gearshape" : "folder.badge.magnifyingglass")
                .font(.system(size: 25, weight: .light)).foregroundStyle(SiftChartStyle.secondaryText)
            Text(busy ? "Finding what’s taking up space" : StoragePrivacyPolicy().isProtected(path) ? "Privacy-protected location" : "Explore \(folderName)")
                .font(.callout.weight(.semibold))
            Text(busy ? "Folders appear as they finish. You can close this menu while the scan continues."
                      : StoragePrivacyPolicy().isProtected(path) ? "Excluded from broad scans. Scan this location only if you want to grant access when macOS asks."
                      : "Scan to see the largest folders and files here. Nothing is scanned or deleted automatically.")
                .font(.caption).foregroundStyle(SiftChartStyle.secondaryText)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity).padding(.horizontal, 25).padding(.vertical, 28).siftStorageSurface()
    }

    private var explorerHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(folderName).font(.system(size: 18, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 5)
            if let total = measurement?.totalBytes {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(measurement?.limitedAccess == true ? "≥ " : "")\(ByteFormatting.string(total))")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                        .help("Stored data attributed to this scan, not guaranteed cleanup savings. Shared blocks may overlap other locations.")
                    Text("in this scan").font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
                }
            }
            if busy {
                Button(overview.cancellingPaths.contains(path) ? "Stopping…" : "Cancel") { overview.cancel(path) }
                    .buttonStyle(SiftQuietButtonStyle()).disabled(overview.cancellingPaths.contains(path))
            } else {
                StorageScanButton(title: measurement == nil ? (path == StorageOverviewService.rootPath ? "Scan volume" : "Scan folder") : "Scan again", disabled: app.isCleaning) { requestScan() }
                    .help("Scan \(path). No files are changed.")
            }
            Menu {
                Button("Reveal in Finder") { reveal(path) }
                Button("Copy path") { copyPath(path) }
                Divider()
                Button("Full rescan (ignore cache)") { requestScan(fullRescan: true) }.disabled(busy)
            } label: { Image(systemName: "ellipsis.circle").font(.callout) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Actions for current folder")
        }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 8) {
            Button {
                if let parent = StorageExplorerResults.breadcrumbs(path).dropLast().last { overview.location = parent.path }
            } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).disabled(path == StorageOverviewService.rootPath)
                .keyboardShortcut("[", modifiers: .command).help("Parent folder")
            ScrollViewReader { scroll in
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(StorageExplorerResults.breadcrumbs(path)) { crumb in
                            if crumb.path != StorageOverviewService.rootPath {
                                Image(systemName: "chevron.right").font(.system(size: 7)).foregroundStyle(SiftChartStyle.mutedText)
                            }
                            Button(crumb.name) { overview.location = crumb.path }
                                .buttonStyle(.plain)
                                .foregroundStyle(crumb.path == path ? Color.primary : SiftChartStyle.secondaryText)
                                .help(crumb.path).id(crumb.path)
                        }
                    }.padding(.vertical, 2)
                }.scrollIndicators(.hidden)
                    .onAppear { scroll.scrollTo(path, anchor: .trailing) }
                    .onChange(of: path) { _, value in scroll.scrollTo(value, anchor: .trailing) }
            }
        }.font(.caption2).help(path)
    }

    private var scanStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.mini) }
                else {
                    Circle().fill(scanState.needsAttention ? Color.orange : SiftChartStyle.mutedText).frame(width: 5, height: 5)
                }
                Text(busy || measurement == nil ? scanState.title : "\(scanState == .ready ? "Saved scan" : scanState.title) · not live").font(.caption2).lineLimit(2)
                Spacer()
                if !busy, let measurement {
                    Text("\(measurement.date.formatted(.dateTime.day().month(.abbreviated))) · \(measurement.date.formatted(.dateTime.hour().minute()))")
                        .font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
                }
            }
            if let progress = overview.progress[path] { progressView(progress) }
            else if case .queued = scanState {
                Text("This folder will run when earlier scans finish.")
                    .font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
            }
        }.foregroundStyle(SiftChartStyle.secondaryText).padding(.vertical, 3)
    }

    private func progressView(_ progress: StorageScanProgress) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = Int(max(0, context.date.timeIntervalSince(progress.startedAt)))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("\(progress.completedDirectories.formatted()) folders checked")
                    Spacer()
                    Text(elapsed < 60 ? "\(elapsed)s" : "\(elapsed / 60)m \(elapsed % 60)s")
                }
                if let current = progress.currentPath {
                    Text(current).lineLimit(1).truncationMode(.middle).help(current)
                }
                if measurement != nil { Text("Updating results · earlier folder values may remain until refreshed.") }
            }.font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
        }
    }

    private func results(_ measurement: StorageMeasurement) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            resultControls
            if filesMode { fileResults(measurement) } else { folderResults(measurement) }
            if !filesMode, overview.progress[path] == nil, let baseline,
               measurement.isComplete, !measurement.limitedAccess {
                DisclosureGroup("Folder growth") {
                    FolderGrowthView(current: measurement, previous: baseline).padding(.top, 8)
                }.font(.caption).foregroundStyle(SiftChartStyle.secondaryText).padding(.top, 5)
            }
        }
    }

    private var resultControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 18) {
                modeTab("Folders", files: false, count: measurement?.folders.count)
                modeTab("Largest files", files: true, count: measurement?.largeFiles?.count)
                Spacer(minLength: 0)
            }.overlay(alignment: .bottom) { Rectangle().fill(SiftChartStyle.rule).frame(height: 0.5).allowsHitTesting(false) }
            HStack(spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(SiftChartStyle.mutedText)
                    TextField(filesMode ? "Filter these files" : "Filter these folders", text: $query)
                        .textFieldStyle(.plain).font(.caption).accessibilityLabel("Filter measured results")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Clear filter")
                    }
                }.padding(8).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                Menu {
                    Picker("Sort results", selection: $sort) {
                        ForEach(StorageExplorerSort.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                                .disabled(option == .growth && (filesMode || baseline == nil || measurement?.isComplete != true || measurement?.limitedAccess == true))
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(effectiveSort == .size ? "Size" : effectiveSort == .growth ? "Growth" : "Name")
                        Image(systemName: "arrow.up.arrow.down")
                    }.font(.caption2)
                }.menuStyle(.borderlessButton).fixedSize().help("Sort: \(effectiveSort.rawValue)")
                    .accessibilityLabel("Sort results: \(effectiveSort.rawValue)")
            }
        }
    }

    private func modeTab(_ title: String, files: Bool, count: Int?) -> some View {
        let selected = filesMode == files
        return Button { filesMode = files } label: {
            HStack(spacing: 5) {
                Text(title).font(.caption.weight(selected ? .semibold : .regular))
                if let count { Text(count.formatted()).font(.caption2.monospacedDigit()).foregroundStyle(SiftChartStyle.mutedText) }
            }
            .foregroundStyle(selected ? Color.primary : SiftChartStyle.secondaryText)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                Capsule().fill(selected ? SiftChartStyle.accent : .clear).frame(height: 2).allowsHitTesting(false)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var effectiveSort: StorageExplorerSort {
        sort == .growth && (filesMode || baseline == nil || measurement?.isComplete != true || measurement?.limitedAccess == true) ? .size : sort
    }

    private func folderResults(_ measurement: StorageMeasurement) -> some View {
        let rows = StorageExplorerResults.folders(measurement, query: query, sort: effectiveSort, baseline: baseline)
        return VStack(alignment: .leading, spacing: 8) {
            if !query.isEmpty {
                Text("\(rows.count) matching folders").font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
            }
            if rows.isEmpty {
                emptyResults(!query.isEmpty ? "No measured folders match this filter." : busy ? "Measuring subfolders… completed results will appear here." : "No readable subfolders found. Check Largest files for files stored here.")
                if query.isEmpty, (measurement.fileCount ?? 0) > 0 {
                    Button("View largest files") { filesMode = true }.buttonStyle(SiftQuietButtonStyle())
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { folder in
                        explorerRow(path: folder.path, name: folder.name, bytes: folder.bytes,
                            limited: folder.limitedAccess == true, privacySkipped: folder.privacySkipped == true, isFile: false,
                            detail: growthDetail(folder, measurement: measurement), shared: false)
                        if folder.id != rows.last?.id { Divider().padding(.horizontal, 12) }
                    }
                }.siftStorageSurface()
            }
        }
    }

    private func fileResults(_ measurement: StorageMeasurement) -> some View {
        let rows = StorageExplorerResults.files(measurement, query: query, sort: effectiveSort)
        return VStack(alignment: .leading, spacing: 8) {
            if measurement.largeFiles == nil {
                emptyResults(busy ? "Looking for large files… results will appear as the scan progresses." : "This scan has folder sizes only. Refresh this location to look for large files. File lists require a native APFS scan.")
            } else {
                Text("\(measurement.largeFiles?.count ?? 0) largest of \((measurement.fileCount ?? 0).formatted()) files checked\(query.isEmpty ? "" : " · \(rows.count) matches")")
                    .font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
                    .help("Includes subfolders. Filters search only this largest-file sample; file sizes overlap folder totals and are not exclusive savings.")
                if rows.isEmpty {
                    emptyResults(!query.isEmpty ? "No files in the largest-\(StorageExplorerResults.fileLimit) sample match. Scan a narrower folder to discover more." : busy ? "Looking for large files… results will appear as the scan progresses." : "No regular files found in the readable part of this scan.")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { file in
                            explorerRow(path: file.path, name: file.name, bytes: file.bytes,
                                limited: false, privacySkipped: false, isFile: true,
                                detail: "\(file.shared ? "Shared · " : "")\(ByteFormatting.string(file.logicalBytes)) logical · \(relative(file.path))", shared: file.shared)
                            if file.id != rows.last?.id { Divider().padding(.horizontal, 12) }
                        }
                    }.siftStorageSurface()
                }
            }
        }
    }

    private func explorerRow(path rowPath: String, name: String, bytes: Int64,
                             limited: Bool, privacySkipped: Bool, isFile: Bool, detail: String?, shared: Bool) -> some View {
        let context = StoragePathContext.classify(rowPath, caches: app.globalCaches, workspaces: app.workspaces)
        return HStack(spacing: 8) {
            Button {
                if isFile { reveal(rowPath) } else { overview.location = rowPath }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: privacySkipped ? "lock" : isFile ? "doc" : "folder")
                        .font(.system(size: 14)).foregroundStyle(context.color)
                        .frame(width: 28, height: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        if let subtitle = privacySkipped ? "Privacy protected" : detail ?? (context.target != nil || context.label == "Personal data" ? context.label : nil) {
                            Text(subtitle).font(.caption2).foregroundStyle(SiftChartStyle.mutedText).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 3)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(privacySkipped ? "Skipped" : limited ? (bytes > 0 ? "≥ \(ByteFormatting.string(bytes))" : "Unavailable") : ByteFormatting.string(bytes))
                            .font(.caption.weight(.medium).monospacedDigit())
                        if shared || limited {
                            Text(limited ? "Limited access" : "Shared").font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
                        }
                    }
                    Image(systemName: isFile ? "arrow.up.forward.square" : "chevron.right")
                        .font(.system(size: 9)).foregroundStyle(SiftChartStyle.mutedText)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(isFile ? "Reveal in Finder · never opens or deletes this file" : "Explore folder")
            Menu {
                Button("Reveal in Finder") { reveal(rowPath) }
                Button("Copy path") { copyPath(rowPath) }
                if !isFile { Button("Scan this folder…") { overview.location = rowPath; requestScan() } }
                if let target = context.target {
                    Divider()
                    Button("Review \(target.name) cleanup…") { onReviewCleanup(target) }
                        .help(target.scopeDescription)
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Actions for \(name)")
        }.padding(.horizontal, 10).padding(.vertical, 10)
    }

    private func emptyResults(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(SiftChartStyle.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12).siftStorageSurface()
    }

    private func growthDetail(_ folder: StorageFolder, measurement: StorageMeasurement) -> String? {
        guard overview.progress[path] == nil, measurement.isComplete, !measurement.limitedAccess, let baseline else { return nil }
        let prior = baseline.folders.first { $0.path == folder.path }?.bytes ?? 0
        let delta = folder.bytes - prior
        guard delta != 0 else { return nil }
        return "\(delta > 0 ? "+" : "−")\(ByteFormatting.string(abs(delta))) since \(baseline.date.formatted(date: .abbreviated, time: .omitted))"
    }



    @ViewBuilder private func accounting(_ measurement: StorageMeasurement) -> some View {
        if measurement.privacyExcluded == true {
            Text("Protected folders were excluded, not measured as empty. Their storage is missing from this scan’s total.")
            if let paths = measurement.excludedPaths, !paths.isEmpty {
                ForEach(paths, id: \.self) { Text($0).textSelection(.enabled) }
            }
        }
        if let total = measurement.totalBytes {
            let directFiles = max(0, total - measurement.folders.reduce(0) { $0 + $1.bytes })
            if directFiles > 0 {
                HStack { Text("Files & metadata directly here"); Spacer(); Text(ByteFormatting.string(directFiles)).monospacedDigit() }
                    .font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
            }
        }
        if path == StorageOverviewService.rootPath, let capacity = app.diskCapacity(), let free = app.freeDiskSpace(),
           let difference = measurement.volumeDifference(usedBytes: capacity - free) {
            DisclosureGroup {
                Text("Protected files, other APFS volumes, metadata, and shared blocks can cause this difference. It is not a cleanup target.")
                    .font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
            } label: {
                HStack {
                    Text("Volume accounting difference")
                    Spacer()
                    Text("\(difference < 0 ? "−" : "")\(ByteFormatting.string(abs(difference)))").monospacedDigit()
                }.font(.caption2)
            }
        }
        if overview.progress[path] == nil, baseline == nil {
            Text("Scan this folder again later to compare growth.").font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
        }
    }

    private func relative(_ file: String) -> String {
        let prefix = path == "/" ? "/" : path + "/"
        return file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : file
    }
    private func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    private func requestScan(fullRescan: Bool = false) {
        guard !busy else { return }
        if StoragePrivacyPolicy().isProtected(path) {
            protectedScanPath = path
            protectedFullRescan = fullRescan
            confirmProtectedScan = true
        } else {
            overview.scanCurrentFolder(fullRescan: fullRescan)
        }
    }
    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
