import ImageIO
import PhotosUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import Vision

/// A photo picked to send, already shrunk to the JPEG the server gets.
/// Photos of one meal, between picking them and logging them with their description.
struct PickedMeal: Identifiable {
    let id = UUID()
    let photos: [PickedPhoto]
}

struct PickedPhoto: Identifiable, Equatable {
    let id = UUID()
    let jpeg: Data
    let preview: UIImage
    /// Food barcodes in the photo, read on the phone when the screen asks for them (`photoSources(barcodes:)`).
    var barcodes: [String] = []

    init?(jpeg: Data) {
        guard let preview = UIImage(data: jpeg) else { return nil }
        self.jpeg = jpeg
        self.preview = preview
    }
}

/// Photos go up as JPEG with the longest side at most 1568 px, what the model reads best (docs/API.md, "Photos").
enum PhotoPrep {
    static let longest: CGFloat = 1568
    static let quality: CGFloat = 0.75

    /// `size` scaled down to fit `longest` on its longer side; a smaller one stays as it is.
    static func fitted(_ size: CGSize, longest: CGFloat = longest) -> CGSize {
        let scale = min(1, longest / max(size.width, size.height, 1))
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    #if os(iOS)
    /// A camera photo: drawn upright at the smaller size.
    static func jpeg(_ image: UIImage) -> Data? {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let target = fitted(pixels)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).jpegData(withCompressionQuality: quality) { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
    #endif

    /// A library photo (HEIC, JPEG, PNG…): decoded straight at the smaller size and turned upright, so a 48 MP
    /// photo never sits in memory at full size.
    static func jpeg(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: quality)
    }
}

extension View {
    /// The camera and the photo library for a screen that sends photos: set `camera` or `library` to open one.
    /// Photos arrive shrunk, at most `limit` of them from the library.
    /// With `barcodes`, each photo's food barcodes are read from the full-size picture first.
    func photoSources(camera: Binding<Bool>, library: Binding<Bool>, limit: Int, barcodes: Bool = false,
                      onPick: @escaping ([PickedPhoto]) -> Void) -> some View {
        modifier(PhotoSources(camera: camera, library: library, limit: limit, barcodes: barcodes, onPick: onPick))
    }
}

private struct PhotoSources: ViewModifier {
    @Binding var camera: Bool
    @Binding var library: Bool
    let limit: Int
    let barcodes: Bool
    let onPick: ([PickedPhoto]) -> Void
    @State private var items: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $library, selection: $items, maxSelectionCount: max(limit, 1), matching: .images)
            .onChange(of: items) { _, picked in
                guard !picked.isEmpty else { return }
                items = []
                Task {
                    var photos: [PickedPhoto] = []
                    for item in picked.prefix(max(limit, 1)) {
                        guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                        let (jpeg, codes) = await Task.detached { [barcodes] in
                            (PhotoPrep.jpeg(data), barcodes ? BarcodeReader.codes(in: data) : [])
                        }.value
                        if var photo = jpeg.flatMap(PickedPhoto.init(jpeg:)) {
                            photo.barcodes = codes
                            photos.append(photo)
                        }
                    }
                    if !photos.isEmpty { onPick(photos) }
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $camera) {
                CameraPicker { image in
                    Task {
                        let (jpeg, codes) = await Task.detached { [barcodes] in
                            (PhotoPrep.jpeg(image), barcodes ? BarcodeReader.codes(in: image) : [])
                        }.value
                        if var photo = jpeg.flatMap(PickedPhoto.init(jpeg:)) {
                            photo.barcodes = codes
                            onPick([photo])
                        }
                    }
                }
                .ignoresSafeArea()
            }
            #endif
    }
}

/// Food barcodes (EAN-13, EAN-8, UPC) in a photo, read on the phone with Vision: no request, about 0.1 s.
enum BarcodeReader {
    /// Big enough for a barcode across the room's packet, small enough not to hold a 48 MP photo in memory.
    static let longest: CGFloat = 3072

    /// A library photo, decoded upright at up to `longest`.
    static func codes(in data: Data) -> [String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return [] }
        return codes(in: image)
    }

    #if os(iOS)
    /// A camera photo, as it was taken.
    static func codes(in image: UIImage) -> [String] {
        guard let cg = image.cgImage else { return [] }
        return codes(in: cg, orientation: CGImagePropertyOrientation(image.imageOrientation))
    }
    #endif

    static let symbologies: [VNBarcodeSymbology] = [.ean13, .ean8, .upce]

    /// Digits only, each once, in the order Vision found them.
    static func codes(in image: CGImage, orientation: CGImagePropertyOrientation = .up) -> [String] {
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        let request = VNDetectBarcodesRequest()
        request.symbologies = symbologies
        do {
            try handler.perform([request])
        } catch {
            // The newer revisions need the Neural Engine (none on the Simulator: "Could not create inference
            // context"); the first still reads EAN.
            guard let first = VNDetectBarcodesRequest.supportedRevisions.min() else { return [] }
            request.revision = first
            try? handler.perform([request])
        }
        var found: [String] = []
        for barcode in request.results ?? [] where symbologies.contains(barcode.symbology) {
            guard let code = barcode.payloadStringValue?.filter(\.isNumber), code.count >= 6,
                  !found.contains(code) else { continue }
            found.append(code)
        }
        return found
    }
}

#if os(iOS)
private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// The system camera, for one photo.
struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    /// No camera on the Simulator.
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPick(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
#endif

/// A photo on the server, fetched with the API token (AsyncImage can't send it) and kept in memory. `local` shows
/// one still on its way up. `fit` keeps its shape; otherwise it fills the frame it's given.
struct ServerPhoto: View {
    @EnvironmentObject private var env: AppEnvironment
    let id: String?
    var local: Data?
    var fit = false
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        if let image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
        } else {
            Theme.chip
                .overlay {
                    if failed { Image(systemName: "photo").foregroundStyle(.secondary) } else { ProgressView() }
                }
                .task(id: id) { await load() }
        }
    }

    private func load() async {
        if let local, let decoded = UIImage(data: local) { image = decoded; return }
        guard let id, let data = try? await env.api.photo(id), let decoded = UIImage(data: data) else {
            failed = true
            return
        }
        image = decoded
    }
}
