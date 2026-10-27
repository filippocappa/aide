import ImageIO
import PhotosUI
import SwiftUI
import UIKit

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
    func photoSources(camera: Binding<Bool>, library: Binding<Bool>, limit: Int,
                      onPick: @escaping ([PickedPhoto]) -> Void) -> some View {
        modifier(PhotoSources(camera: camera, library: library, limit: limit, onPick: onPick))
    }
}

private struct PhotoSources: ViewModifier {
    @Binding var camera: Bool
    @Binding var library: Bool
    let limit: Int
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
                        let jpeg = await Task.detached { PhotoPrep.jpeg(data) }.value
                        if let photo = jpeg.flatMap(PickedPhoto.init(jpeg:)) { photos.append(photo) }
                    }
                    if !photos.isEmpty { onPick(photos) }
                }
            }
            .fullScreenCover(isPresented: $camera) {
                CameraPicker { image in
                    Task {
                        let jpeg = await Task.detached { PhotoPrep.jpeg(image) }.value
                        if let photo = jpeg.flatMap(PickedPhoto.init(jpeg:)) { onPick([photo]) }
                    }
                }
                .ignoresSafeArea()
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
