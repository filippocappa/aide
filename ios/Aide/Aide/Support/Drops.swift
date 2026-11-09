import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// A PDF picked or dropped for a chat message (#78): a copy in the temporary folder until it's sent.
struct PickedFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let name: String
    let pages: Int?

    /// A PDF already in a folder of the app's own (a drop's copy).
    init(url: URL) {
        self.url = url
        name = url.lastPathComponent
        pages = PDFDocument(url: url)?.pageCount
    }

    /// A copy of a PDF chosen in Files, in a folder of the app's own, keeping its name.
    static func copy(of source: URL) -> PickedFile? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drops/\(UUID().uuidString)")
        let target = folder.appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            return nil
        }
        return PickedFile(url: target)
    }
}

/// What came off a drop: photos ready to send, PDFs, and other files a page takes (a course's recordings) as copies.
struct Dropped {
    var photos: [PickedPhoto] = []
    var files: [PickedFile] = []
    var others: [URL] = []
    var isEmpty: Bool { photos.isEmpty && files.isEmpty && others.isEmpty }
}

/// What a page takes when something is dragged over it, and what it says it will do.
struct DropSpec {
    /// One line on what happens: "Drop to add to the chat with Professor".
    var title: String
    /// Under it: what it takes ("Photos and PDFs").
    var detail: String = "Photos and PDFs"
    var symbol: String = "arrow.down.doc"
    var tint: Color = Theme.accent
    /// Shown instead of the symbol: the agent the drop goes to, its Pebble in its colour.
    var agent: Agent?
    var accepts: [UTType] = [.image, .pdf]
    /// Said when what's dragged isn't taken here.
    var refusal = "Only photos and PDFs can go here"
    /// Read food barcodes in dropped photos (Coach).
    var barcodes = false
    /// Photos a drop may still add (a message takes `PhotoLimit.message`); PDFs as many.
    var photoLimit = PhotoLimit.message
}

extension View {
    /// Takes photos, PDFs (and whatever else `spec` accepts) dragged onto the view, with an overlay while they're over
    /// it that says what will happen, or that they aren't taken here. Screenshots come either way: a file from the
    /// desktop, or straight from the thumbnail.
    func dropZone(_ spec: DropSpec, enabled: Bool = true, onDrop: @escaping (Dropped) -> Void) -> some View {
        modifier(DropZone(spec: spec, enabled: enabled, onDrop: onDrop))
    }
}

private struct DropZone: ViewModifier {
    let spec: DropSpec
    let enabled: Bool
    let onDrop: (Dropped) -> Void
    #if DEBUG
    /// Simulator screenshots: `-previewDrop takes` (or `refused`, `closed`) shows the overlay with nothing dragged.
    @State private var hovering = DropOverlay.State(rawValue: UserDefaults.standard.string(forKey: "previewDrop") ?? "")
    #else
    @State private var hovering: DropOverlay.State?
    #endif

    func body(content: Content) -> some View {
        content
            .overlay {
                if let hovering {
                    DropOverlay(spec: spec, state: hovering)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(.easeOut(duration: 0.16), value: hovering)
            .onDrop(of: [.item], delegate: Delegate(spec: spec, enabled: enabled, hovering: $hovering, onDrop: onDrop))
    }

    private struct Delegate: DropDelegate {
        let spec: DropSpec
        let enabled: Bool
        @Binding var hovering: DropOverlay.State?
        let onDrop: (Dropped) -> Void

        private func takes(_ info: DropInfo) -> Bool {
            enabled && info.hasItemsConforming(to: spec.accepts)
        }

        func validateDrop(info: DropInfo) -> Bool { true } // a refused one still shows why

        func dropEntered(info: DropInfo) {
            hovering = !enabled ? .closed : takes(info) ? .takes : .refused
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: takes(info) ? .copy : .forbidden)
        }

        func dropExited(info: DropInfo) { hovering = nil }

        func performDrop(info: DropInfo) -> Bool {
            hovering = nil
            guard takes(info) else { return false }
            let providers = info.itemProviders(for: spec.accepts)
            Task { @MainActor in
                let dropped = await Self.load(providers, spec: spec)
                if !dropped.isEmpty { onDrop(dropped) }
            }
            return true
        }

        /// Each item as the first type it's taken as: a PDF before an image (a PDF can be both), then the page's
        /// other types (a recording).
        @MainActor private static func load(_ providers: [NSItemProvider], spec: DropSpec) async -> Dropped {
            var out = Dropped()
            for provider in providers {
                if spec.accepts.contains(.pdf), provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                    if let url = await copy(provider, type: .pdf) { out.files.append(PickedFile(url: url)) }
                } else if spec.accepts.contains(.image), provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    guard out.photos.count < spec.photoLimit, let data = await data(provider, type: .image) else { continue }
                    let (jpeg, codes) = await Task.detached { [barcodes = spec.barcodes] in
                        (PhotoPrep.jpeg(data), barcodes ? BarcodeReader.codes(in: data) : [])
                    }.value
                    if var photo = jpeg.flatMap(PickedPhoto.init(jpeg:)) {
                        photo.barcodes = codes
                        out.photos.append(photo)
                    }
                } else if let type = spec.accepts.first(where: {
                    $0 != .pdf && $0 != .image && provider.hasItemConformingToTypeIdentifier($0.identifier)
                }), let url = await copy(provider, type: type) {
                    out.others.append(url)
                }
            }
            return out
        }

        private static func data(_ provider: NSItemProvider, type: UTType) async -> Data? {
            await withCheckedContinuation { done in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    done.resume(returning: data)
                }
            }
        }

        /// The item as a file of our own: the one the provider hands over is deleted once its callback returns.
        private static func copy(_ provider: NSItemProvider, type: UTType) async -> URL? {
            let name = provider.suggestedName
            return await withCheckedContinuation { done in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                    guard let url else { return done.resume(returning: nil) }
                    var named = name ?? url.lastPathComponent
                    if (named as NSString).pathExtension.isEmpty,
                       let ext = url.pathExtension.isEmpty ? type.preferredFilenameExtension : url.pathExtension {
                        named += "." + ext
                    }
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drops/\(UUID().uuidString)")
                    let target = folder.appendingPathComponent(named)
                    do {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: url, to: target)
                        done.resume(returning: target)
                    } catch {
                        done.resume(returning: nil)
                    }
                }
            }
        }
    }
}

/// The glass over a page while something is dragged on it: Pebble or an icon, and what the drop will do.
struct DropOverlay: View {
    enum State: String, Equatable { case takes, refused, closed }
    let spec: DropSpec
    let state: State

    private var takes: Bool { state == .takes }
    private var tint: Color { takes ? (spec.agent?.tint ?? spec.tint) : .secondary }
    private static let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

    var body: some View {
        ZStack {
            Self.shape.fill(.ultraThinMaterial)
            Self.shape.fill(tint.opacity(takes ? 0.10 : 0.04))
            Self.shape.strokeBorder(tint.opacity(takes ? 0.75 : 0.35),
                                    style: StrokeStyle(lineWidth: 2, dash: takes ? [] : [9, 7]))
            VStack(spacing: 14) {
                icon
                VStack(spacing: 4) {
                    Text(title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .padding(10)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        if takes, let agent = spec.agent {
            LivePebble(mood: "awake", size: 72, figure: agent.figure)
                .foregroundStyle(agent.tint)
        } else {
            Image(systemName: takes ? spec.symbol : "nosign")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 76, height: 76)
                .background(tint.opacity(0.14), in: Circle())
                .symbolEffect(.bounce, value: takes)
        }
    }

    private var title: String {
        switch state {
        case .takes: spec.title
        case .refused: spec.refusal
        case .closed: "Not now"
        }
    }

    private var detail: String {
        switch state {
        case .takes: spec.detail
        case .refused: "Let go to cancel"
        case .closed: "Connect to your server in Settings first"
        }
    }
}
