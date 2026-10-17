import AppKit
import CleanerCore
import SwiftUI

struct FilesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.filesTool {
            case .largeFiles: LargeFilesView()
            case .duplicates: DuplicatesView()
            case .diskMap: DiskMapView()
            }
        }
        .navigationTitle(Text(SidebarItem.files.title))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(selection: $model.filesTool) {
                    ForEach(FilesTool.allCases) { tool in
                        Text(tool.title).tag(tool)
                    }
                } label: {
                    Text(SidebarItem.files.title)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

// MARK: - Disk map

private struct DiskMapView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingTrash: DiskNode?
    /// The entry under the pointer, in the map or in the list. Both highlight it.
    @State private var hovered: String?

    var body: some View {
        let map = model.diskMap
        // The scroll view comes first: in the detail column, fixed content above a scroll view pushes the window layout around.
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageHeader(title: "Disk Map", subtitle: "An interactive map of what fills your disk.")
                    HStack(spacing: 10) {
                        Breadcrumb()
                        Spacer()
                        if map.phase == .scanning {
                            Button("Stop") { map.cancel() }
                        } else {
                            Button("Choose Folder…") { chooseFolder() }
                            Button {
                                map.scan(map.root?.url ?? URL.homeDirectory)
                            } label: {
                                Label(map.root == nil ? "Scan Home Folder" as LocalizedStringResource : "Scan Again", systemImage: "magnifyingglass")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    if let report = map.lastReport {
                        RemovalSummary(report: report)
                    }

                    switch map.phase {
                    case .idle:
                        Card {
                            Label {
                                Text("XCleaner measures every folder once, then shows what takes up the most space. Click a folder to look inside it.")
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "chart.pie")
                                    .foregroundStyle(.tint)
                            }
                        }
                        ComingLaterSection(item: .files)
                    case .scanning:
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Looked at \(map.filesSeen) files…")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    case .ready:
                        if let node = map.current {
                            let height = max(320, proxy.size.height - 220)
                            HStack(alignment: .top, spacing: 16) {
                                TreemapView(node: node, hovered: $hovered, open: { map.open($0) }, trash: { pendingTrash = $0 })
                                    .frame(maxWidth: .infinity)
                                    .frame(height: height)
                                ChildList(node: node, hovered: $hovered, trash: { pendingTrash = $0 })
                                    .frame(width: 300, height: height)
                            }
                        }
                    }
                }
                .padding(28)
            }
        }
        .confirmationDialog(
            Text("Move “\(pendingTrash?.name ?? "")” to the Trash?"),
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash") {
                if let node = pendingTrash {
                    Task {
                        await map.moveToTrash(node, with: model.makeServices(), method: Preferences.deletionMethod)
                        model.refresh()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Preferences.deletionMethod == .dryRun
                ? "Test Mode is on, so nothing will be removed. You'll see what would have happened." as LocalizedStringResource
                : "\(pendingTrash?.size.formattedBytes ?? "") goes to the Trash, where you can put it back.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Scan")
        if panel.runModal() == .OK, let url = panel.url {
            model.diskMap.scan(url)
        }
    }
}

private struct Breadcrumb: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let trail = model.diskMap.trail
        HStack(spacing: 4) {
            ForEach(Array(trail.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    model.diskMap.goBack(to: node)
                } label: {
                    Text(verbatim: index == 0 ? (node.url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath : node.name)
                        .lineLimit(1)
                }
                .buttonStyle(.link)
                .disabled(index == trail.count - 1)
            }
        }
    }
}

/// One tile of the map: a folder, a big file, or everything too small to show on its own.
private struct Tile: Identifiable {
    let id: String
    let name: String
    let size: Int64
    let node: DiskNode?

    var canOpen: Bool { node?.canOpen == true }

    var systemImage: String {
        guard let node else { return "ellipsis" }
        return node.isDirectory ? "folder.fill" : "doc.fill"
    }
}

private func tiles(for node: DiskNode) -> [Tile] {
    var tiles = node.children.map { Tile(id: $0.url.path(percentEncoded: false), name: $0.name, size: $0.size, node: $0) }
    if node.otherBytes > 0 {
        tiles.append(Tile(id: "other", name: String(localized: "Smaller items"), size: node.otherBytes, node: nil))
    }
    return tiles.sorted { $0.size > $1.size }
}

private let palette: [Color] = [.teal, .blue, .indigo, .purple, .pink, .orange, .yellow, .green, .mint, .cyan]

private struct TreemapView: View {
    let node: DiskNode
    @Binding var hovered: String?
    let open: (DiskNode) -> Void
    let trash: (DiskNode) -> Void
    /// Where the pointer is over the map. The tile under it gets a tooltip, so even the smallest ones can be told apart.
    @State private var pointer: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let entries = tiles(for: node)
            let frames = Treemap.layout(entries.map { Double($0.size) }, in: CGRect(origin: .zero, size: size))
            let tileIndex = { (point: CGPoint?) in point.flatMap { point in frames.firstIndex { $0.contains(point) } } }
            let pointed = tileIndex(pointer)
            // Over the map, the tile under the pointer lights up; otherwise the one hovered in the list does.
            let highlighted = pointed.map { entries[$0].id } ?? hovered
            ZStack(alignment: .topLeading) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, tile in
                    let frame = frames[index]
                    TileView(tile: tile, color: tile.node == nil ? Color.gray : palette[index % palette.count], isHovered: highlighted == tile.id)
                        .frame(width: max(0, frame.width - 3), height: max(0, frame.height - 3))
                        .onTapGesture { if let child = tile.node { open(child) } }
                        .clickablePointer(tile.canOpen)
                        .contextMenu {
                            if let child = tile.node {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([child.url]) }
                                Button("Move to Trash…") { trash(child) }
                            }
                        }
                        // `position` rather than `offset`, so the pointer areas follow the tile.
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            // Hover only counts drawn content: this all but invisible fill keeps the gaps between tiles part of the map,
            // so the tooltip doesn't blink while the pointer crosses them.
            .background(Color.primary.opacity(0.001))
            .onContinuousHover { phase in
                let previous = tileIndex(pointer).map { entries[$0].id }
                switch phase {
                case .active(let point): pointer = point
                case .ended: pointer = nil
                }
                if let index = tileIndex(pointer) {
                    if hovered != entries[index].id { hovered = entries[index].id }
                } else if hovered == previous {
                    // Off the tiles. A row the pointer has already reached in the list keeps its highlight.
                    hovered = nil
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if let pointer, let pointed {
                    let tile = entries[pointed]
                    TooltipLayout(anchor: pointer) {
                        TileTooltip(tile: tile, share: node.size > 0 ? Double(tile.size) / Double(node.size) : 0)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

/// Puts the tooltip next to the pointer: after it on each axis when there is room, before it otherwise, and always inside the map.
/// It also caps the tooltip's width, so a long name wraps instead of stretching it.
private struct TooltipLayout: Layout {
    let anchor: CGPoint

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let tooltip = subviews.first else { return }
        let size = tooltip.sizeThatFits(ProposedViewSize(width: min(bounds.width, 300), height: nil))
        let x = tooltipOrigin(anchor.x, length: size.width, room: bounds.width, gap: 14)
        let y = tooltipOrigin(anchor.y, length: size.height, room: bounds.height, gap: 18)
        tooltip.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
    }
}

/// Where the tooltip starts along one axis.
nonisolated private func tooltipOrigin(_ pointer: CGFloat, length: CGFloat, room: CGFloat, gap: CGFloat) -> CGFloat {
    if pointer + gap + length <= room { return pointer + gap }
    return max(0, min(pointer - gap - length, room - length))
}

private struct TileView: View {
    let tile: Tile
    let color: Color
    let isHovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color.opacity(isHovered ? 0.95 : 0.7))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(isHovered ? 0.85 : 0), lineWidth: 2)
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    if proxy.size.width > 70, proxy.size.height > 36 {
                        VStack(alignment: .leading, spacing: 1) {
                            Label {
                                Text(verbatim: tile.name)
                                    .lineLimit(1)
                            } icon: {
                                Image(systemName: tile.systemImage)
                            }
                            .font(.caption.weight(.semibold))
                            Text(tile.size.formattedBytes)
                                .font(.caption2)
                                .monospacedDigit()
                                .opacity(0.85)
                        }
                        .foregroundStyle(.white)
                        .padding(6)
                    }
                }
            }
    }
}

/// Follows the pointer over the map with the name and size of the tile under it.
private struct TileTooltip: View {
    let tile: Tile
    /// The tile's part of the folder on screen, from 0 to 1.
    let share: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(verbatim: tile.name)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: tile.systemImage)
                    .foregroundStyle(.secondary)
            }
            .font(.callout.weight(.semibold))
            Text(verbatim: "\(tile.size.formattedBytes) · \(shareText)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if tile.canOpen {
                Text("Click to look inside")
                    .font(.caption)
                    .foregroundStyle(.tint)
            } else if tile.node == nil {
                Text("Files and folders too small to show one by one")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    private var shareText: String {
        let style = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0...1))
        // Tiles in a big folder can be a sliver of it; "0%" would read as empty.
        return share > 0 && share < 0.001 ? "<" + 0.001.formatted(style) : share.formatted(style)
    }
}

private struct ChildList: View {
    @Environment(AppModel.self) private var model
    let node: DiskNode
    @Binding var hovered: String?
    let trash: (DiskNode) -> Void

    var body: some View {
        let entries = tiles(for: node)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(verbatim: node.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(node.size.formattedBytes)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                RowsCard(Array(entries.enumerated())) { index, entry in
                    ChildRow(
                        entry: entry,
                        color: entry.node == nil ? Color.gray : palette[index % palette.count],
                        share: node.size > 0 ? Double(entry.size) / Double(node.size) : 0,
                        isHovered: hovered == entry.id
                    )
                    .onHover { inside in
                        if inside {
                            hovered = entry.id
                        } else if hovered == entry.id {
                            hovered = nil
                        }
                    }
                    .onTapGesture { if let child = entry.node { model.diskMap.open(child) } }
                    .clickablePointer(entry.canOpen)
                    .contextMenu {
                        if let child = entry.node {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([child.url]) }
                            Button("Move to Trash…") { trash(child) }
                        }
                    }
                }
            }
        }
    }
}

/// One entry beside the map. Folders that open show a chevron and light up in the accent color under the pointer.
private struct ChildRow: View {
    let entry: Tile
    let color: Color
    let share: Double
    let isHovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(verbatim: entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(entry.size.formattedBytes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if entry.canOpen {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isHovered ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
            }
            ProgressView(value: share)
                .controlSize(.mini)
        }
        .background {
            // Hover only counts drawn content, so an all but invisible fill makes the whole row react to the pointer,
            // the gaps between rows included, not just its text.
            Color.primary.opacity(0.001)
                .padding(.horizontal, -14)
                .padding(.vertical, -7)
        }
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? (entry.canOpen ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.07)) : Color.clear)
                .padding(.horizontal, -8)
                .padding(.vertical, -4)
        }
    }
}

private extension View {
    /// The pointing hand over things that open when clicked.
    @ViewBuilder
    func clickablePointer(_ isClickable: Bool) -> some View {
        if #available(macOS 15, *) {
            pointerStyle(isClickable ? .link : nil)
        } else {
            self
        }
    }
}
