import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// One image Pi is holding.
struct PocketItem: Identifiable, Equatable {
    let url: URL
    let added: Date
    let thumb: NSImage
    var id: String { url.path }
    static func == (a: PocketItem, b: PocketItem) -> Bool { a.url == b.url && a.added == b.added }
}

/// Pi's pocket: a tiny image shelf. Drop screenshots/images on Pi, drag them back out later.
/// Files live in ~/Library/Application Support/PiePet/Pocket so they survive restarts.
@MainActor
final class PocketStore: ObservableObject {
    static let capacity = 6

    @Published private(set) var items: [PocketItem] = []
    /// True while the mouse is over the pocket (shows every item).
    @Published var expanded = false
    /// The pocket sits left of Pi unless Pi is near the left screen edge.
    @Published var onLeft = true
    /// Briefly highlights the tile that was just copied.
    @Published var flashed: String?

    let dir: URL
    /// Lets Pi comment on what happened (set by the app).
    var announce: ((String) -> Void)?

    init(dir: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.dir = dir ?? base.appendingPathComponent("PiePet/Pocket", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
        reload()
    }

    // MARK: Reading the folder

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        var cached: [String: PocketItem] = [:]
        for i in items { cached[i.id] = i }
        let fresh: [PocketItem] = files.compactMap { url in
            guard Self.isImage(url) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let c = cached[url.path], c.added == date { return c }
            guard let thumb = Self.thumbnail(url) else { return nil }
            return PocketItem(url: url, added: date, thumb: thumb)
        }
        let sorted = fresh.sorted { $0.added > $1.added }
        if sorted != items { items = sorted }
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// Small, cheap thumbnail (never decodes the full screenshot).
    static func thumbnail(_ url: URL, maxPixels: Int = 240) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: Taking things in

    static let dragTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier)]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    private static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private static func imagePromises(_ pb: NSPasteboard) -> [NSFilePromiseReceiver] {
        let all = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
        return all.filter { r in r.fileTypes.contains { UTType($0)?.conforms(to: .image) ?? false } }
    }

    /// Whether a drag (or the clipboard) carries an image Pi can hold.
    static func canAccept(_ pb: NSPasteboard) -> Bool {
        let files = fileURLs(pb)
        if !files.isEmpty { return files.contains(where: isImage) }
        if !imagePromises(pb).isEmpty { return true }
        return NSImage.canInit(with: pb)
    }

    /// Takes the image(s) a drag or the clipboard carries. `done` gets how many were added
    /// (it may run later, for apps that hand over files lazily). Returns false if nothing usable.
    @discardableResult
    func take(from pb: NSPasteboard, done: @escaping (Int) -> Void) -> Bool {
        let files = Self.fileURLs(pb)
        if !files.isEmpty {
            let images = files.filter(Self.isImage)
            let n = images.prefix(Self.capacity).filter { add(file: $0) }.count
            settle()
            done(n)
            return n > 0
        }

        let promises = Self.imagePromises(pb)
        if !promises.isEmpty {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PiePetDrop-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            for r in promises {
                r.receivePromisedFiles(atDestination: tmp, options: [:], operationQueue: .main) { [weak self] url, error in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let ok = error == nil && Self.isImage(url) && self.add(file: url)
                        try? FileManager.default.removeItem(at: url)
                        self.settle()
                        done(ok ? 1 : 0)
                    }
                }
            }
            return true
        }

        if let img = NSImage(pasteboard: pb), let png = Self.png(img) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let ok = add(data: png, name: "Pi Pocket \(f.string(from: Date())).png")
            settle()
            done(ok ? 1 : 0)
            return ok
        }
        done(0)
        return false
    }

    private func add(file src: URL) -> Bool {
        // Already in the pocket (e.g. dropped twice)? Just move it to the front.
        let size = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        if let same = items.first(where: { $0.url.lastPathComponent == src.lastPathComponent
            && ((try? $0.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2) == size }) {
            bumpDate(same.url)
            return true
        }
        let dest = uniqueURL(src.lastPathComponent)
        do { try FileManager.default.copyItem(at: src, to: dest) } catch { return false }
        bumpDate(dest)
        return true
    }

    private func add(data: Data, name: String) -> Bool {
        let dest = uniqueURL(name)
        do { try data.write(to: dest) } catch { return false }
        return true
    }

    private func bumpDate(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func uniqueURL(_ name: String) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name)
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            i += 1
        }
        return url
    }

    /// Reload and send the oldest extras to the Trash.
    private func settle() {
        reload()
        guard items.count > Self.capacity else { return }
        for old in items.dropFirst(Self.capacity) { trash(old.url) }
        reload()
    }

    // MARK: Giving things out

    static func png(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// One pasteboard item with both the file and its pixels, so Finder gets a file and chat apps get an image.
    static func pasteboardItem(for url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if UTType(filenameExtension: url.pathExtension) == .png, let data = try? Data(contentsOf: url) {
            item.setData(data, forType: .png)
        } else if let img = NSImage(contentsOf: url), let data = png(img) {
            item.setData(data, forType: .png)
        }
        return item
    }

    func copy(_ item: PocketItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([Self.pasteboardItem(for: item.url)])
        flashed = item.id
        announce?("Copied! ⌘V to paste it anywhere.")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if self?.flashed == item.id { self?.flashed = nil }
        }
    }

    func open(_ item: PocketItem) { NSWorkspace.shared.open(item.url) }
    func reveal(_ item: PocketItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    func openFolder() { NSWorkspace.shared.open(dir) }

    func remove(_ item: PocketItem) {
        trash(item.url)
        reload()
    }

    func clear() {
        for i in items { trash(i.url) }
        reload()
    }

    /// Removed items go to the Trash, so nothing is lost by accident.
    private func trash(_ url: URL) {
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) == nil {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func menu(for item: PocketItem) -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem("Copy") { [weak self] in self?.copy(item) })
        m.addItem(ClosureMenuItem("Open") { [weak self] in self?.open(item) })
        m.addItem(ClosureMenuItem("Show in Finder") { [weak self] in self?.reveal(item) })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Remove from Pocket") { [weak self] in self?.remove(item) })
        m.addItem(ClosureMenuItem("Empty Pocket") { [weak self] in self?.clear() })
        return m
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }
}

// MARK: - Drop target

/// Hosting view that accepts dropped images (used for Pi and the pocket).
final class DropHostingView<Content: View>: NSHostingView<Content> {
    var onTargetChange: ((Bool) -> Void)?
    var onDrop: ((NSPasteboard) -> Bool)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes(PocketStore.dragTypes)
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not used") }

    /// Only drags from other apps (dragging a pocket item back onto Pi does nothing).
    private func accepts(_ s: NSDraggingInfo) -> Bool {
        s.draggingSource == nil && PocketStore.canAccept(s.draggingPasteboard)
    }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        guard accepts(s) else { return [] }
        onTargetChange?(true)
        return .copy
    }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { accepts(s) ? .copy : [] }
    override func draggingExited(_ s: NSDraggingInfo?) { onTargetChange?(false) }
    override func draggingEnded(_ s: NSDraggingInfo) { onTargetChange?(false) }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool { accepts(s) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        onTargetChange?(false)
        return onDrop?(s.draggingPasteboard) ?? false
    }
}

// MARK: - Drag source

/// Invisible AppKit layer over a tile: drag to take the image out, click to copy, double-click to open,
/// right-click for more. Drags are always copies, so Finder never moves the file out of the pocket.
final class PocketDragNSView: NSView, NSDraggingSource {
    var item: PocketItem?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var makeMenu: (() -> NSMenu?)?
    var onDragEnded: (() -> Void)?
    private var down: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) { down = e }

    override func mouseDragged(with e: NSEvent) {
        guard let start = down, let item else { return }
        let dx = e.locationInWindow.x - start.locationInWindow.x, dy = e.locationInWindow.y - start.locationInWindow.y
        guard dx * dx + dy * dy > 16 else { return }
        down = nil
        let thumb = item.thumb
        let scale = 84 / max(thumb.size.width, thumb.size.height, 1)
        let size = NSSize(width: thumb.size.width * scale, height: thumb.size.height * scale)
        let p = convert(start.locationInWindow, from: nil)
        let drag = NSDraggingItem(pasteboardWriter: PocketStore.pasteboardItem(for: item.url))
        drag.setDraggingFrame(NSRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height),
                              contents: thumb)
        let session = beginDraggingSession(with: [drag], event: start, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with e: NSEvent) {
        guard down != nil else { return }
        down = nil
        if e.clickCount >= 2 { onDoubleClick?() } else { onClick?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnded?()
    }
}

struct PocketDragArea: NSViewRepresentable {
    let item: PocketItem
    let pocket: PocketStore

    func makeNSView(context: Context) -> PocketDragNSView { update(PocketDragNSView()) }
    func updateNSView(_ v: PocketDragNSView, context: Context) { _ = update(v) }

    private func update(_ v: PocketDragNSView) -> PocketDragNSView {
        let pocket = pocket, item = item
        v.item = item
        v.onClick = { pocket.copy(item) }
        v.onDoubleClick = { pocket.open(item) }
        v.makeMenu = { pocket.menu(for: item) }
        v.onDragEnded = { pocket.reload() }
        v.toolTip = "\(item.url.lastPathComponent)\nDrag out · click to copy · double-click to open"
        return v
    }
}

// MARK: - Pocket view

/// The pocket next to Pi: a little photo stack, which opens into a tray on hover.
struct PocketView: View {
    @ObservedObject var pocket: PocketStore

    static let tile: CGFloat = 52
    static let gap: CGFloat = 6
    static let pad: CGFloat = 9
    static let collapsed = NSSize(width: 76, height: 70)

    static func expandedSize(count: Int) -> NSSize {
        let rows = CGFloat(max(1, Int(ceil(Double(count) / 3))))
        return NSSize(width: 3 * tile + 2 * gap + 2 * pad + 8,
                      height: 22 + gap + rows * tile + (rows - 1) * gap + 6 + 12 + 2 * pad + 8)
    }

    static func size(for pocket: PocketStore) -> NSSize {
        pocket.expanded ? expandedSize(count: pocket.items.count) : collapsed
    }

    var body: some View {
        let size = Self.size(for: pocket)
        Group {
            if pocket.expanded { tray } else { stack }
        }
        .frame(width: size.width, height: size.height,
               alignment: pocket.onLeft ? .bottomTrailing : .bottomLeading)
        .environment(\.colorScheme, .light)
    }

    // Collapsed: up to three tilted polaroids with a count badge.
    private var stack: some View {
        let shown = Array(pocket.items.prefix(3).enumerated())
        let tilt: Double = pocket.onLeft ? -1 : 1
        return ZStack(alignment: .topTrailing) {
            ZStack {
                ForEach(shown.reversed(), id: \.element.id) { i, item in
                    polaroid(item)
                        .rotationEffect(.degrees(tilt * (i == 0 ? -4 : Double(i) * 7)))
                        .offset(x: tilt * CGFloat(i) * 3, y: CGFloat(-i) * 2)
                }
                if let top = pocket.items.first {
                    PocketDragArea(item: top, pocket: pocket).frame(width: 54, height: 52)
                }
            }
            .frame(width: 66, height: 62)
            if pocket.items.count > 1 {
                Text("\(pocket.items.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Circle().fill(PetDrawing.orange))
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.2))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .offset(x: 4, y: -2)
                    .allowsHitTesting(false)
            }
        }
        .padding(4)
    }

    private func polaroid(_ item: PocketItem) -> some View {
        Image(nsImage: item.thumb)
            .resizable()
            .scaledToFill()
            .frame(width: 44, height: 36)
            .clipped()
            .padding(.horizontal, 3).padding(.top, 3).padding(.bottom, 8)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(PetDrawing.ink.opacity(0.25), lineWidth: 0.6))
            .shadow(color: .black.opacity(0.28), radius: 2.5, y: 1.5)
    }

    // Expanded: a frosted tray with every item.
    private var tray: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            HStack(spacing: 5) {
                Image(systemName: "tray.full.fill").font(.system(size: 11, weight: .semibold))
                Text("Pi's pocket").font(.system(size: 12, weight: .semibold, design: .rounded))
                Text("\(pocket.items.count)/\(PocketStore.capacity)")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundColor(Theme.brown.opacity(0.55))
                Spacer(minLength: 0)
                Button { pocket.clear() } label: {
                    Image(systemName: "trash").font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Empty the pocket (items go to the Trash)")
            }
            .foregroundColor(Theme.brown)
            .frame(height: 22)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.tile), spacing: Self.gap), count: 3),
                      alignment: .leading, spacing: Self.gap) {
                ForEach(pocket.items) { tile($0) }
            }

            Text("Drag out · click to copy")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundColor(Theme.brown.opacity(0.6))
                .frame(height: 12)
        }
        .padding(Self.pad)
        .background(
            ZStack {
                Glass(material: .hudWindow, light: true).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).opacity(0.85)
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.cream.opacity(0.72))
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.brown.opacity(0.55), lineWidth: 1.2))
        .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
        .padding(4)
        .transition(.scale(scale: 0.6, anchor: pocket.onLeft ? .bottomTrailing : .bottomLeading).combined(with: .opacity))
    }

    private func tile(_ item: PocketItem) -> some View {
        let lit = pocket.flashed == item.id
        return Image(nsImage: item.thumb)
            .resizable()
            .scaledToFill()
            .frame(width: Self.tile, height: Self.tile)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(lit ? PetDrawing.greenBot : Color.white.opacity(0.95), lineWidth: lit ? 2.5 : 1.5))
            .overlay(alignment: .bottomTrailing) {
                if lit {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14)).foregroundStyle(.white, PetDrawing.greenBot)
                        .padding(3)
                }
            }
            .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
            .overlay(PocketDragArea(item: item, pocket: pocket))
            .animation(.easeOut(duration: 0.15), value: lit)
    }
}
