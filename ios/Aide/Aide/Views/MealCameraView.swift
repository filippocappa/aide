@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// What the meal camera ends with; Health → Food carries it out once the camera has gone.
enum MealCameraResult {
    case photos([PickedPhoto])
    /// A packet's barcode seen live, with the photo taken as it was tapped.
    case barcode(String, PickedPhoto?)
    case library
    case describe
}

/// Aide's own camera for logging a meal: a few shots of the plate (up to `MealCamera.limit`), or a packet's
/// barcode, read live and logged without a model call. The library and "Describe" are a tap away. Chat photos keep
/// the system camera (`CameraPicker`).
struct MealCameraView: View {
    let tint: Color
    let done: (MealCameraResult) -> Void

    @StateObject private var camera = MealCamera()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var photos: [PickedPhoto] = []
    @State private var flash = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch camera.status {
            case .denied:
                denied
            case .unavailable:
                message("No camera here.", detail: "Choose a photo instead.")
            case .starting:
                EmptyView()
            case .running: // only now: the preview keeps itself upright from the camera's device
                MealCameraPreview(camera: camera)
                    .ignoresSafeArea()
                    .overlay(Color.white.opacity(flash ? 0.7 : 0).ignoresSafeArea())
            }
            VStack(spacing: 0) {
                topBar
                Spacer()
                if let code = camera.barcode, photos.isEmpty {
                    barcodePill(code)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                Spacer()
                bottom
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.2), value: camera.barcode)
        .animation(.easeOut(duration: 0.2), value: photos)
        .task { await camera.start() }
        .onDisappear { camera.stop() }
    }

    private var topBar: some View {
        HStack {
            roundButton("xmark", label: "Close") { dismiss() }
            Spacer()
            Text(photos.isEmpty ? "Your plate, or a packet's barcode" : "Another angle, or Next")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.35), in: Capsule())
            Spacer()
            if camera.hasTorch {
                roundButton(camera.torch ? "bolt.fill" : "bolt.slash", label: camera.torch ? "Light off" : "Light on") {
                    camera.toggleTorch()
                }
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// "Barcode 8001505005707 · Scan": the packet's real numbers, how much you had, no model call.
    private func barcodePill(_ code: String) -> some View {
        Button {
            Task {
                let photo = await camera.capture()
                finish(.barcode(code, photo))
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "barcode.viewfinder")
                Text("Barcode \(code)").monospacedDigit()
                Text("·").foregroundStyle(Theme.slate.opacity(0.6))
                Text("Scan").fontWeight(.bold)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.slate)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Theme.sand, in: Capsule())
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
        .disabled(camera.busy)
        .accessibilityHint("Logs this packet")
    }

    private var bottom: some View {
        VStack(spacing: 14) {
            if !photos.isEmpty {
                HStack(spacing: 8) {
                    ForEach(photos) { photo in
                        Button { photos.removeAll { $0.id == photo.id } } label: {
                            Image(uiImage: photo.preview)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.footnote)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                        .padding(3)
                                }
                        }
                        .accessibilityLabel("Remove this photo")
                    }
                }
            }
            HStack {
                sideButton("photo.on.rectangle", title: "Library") { finish(.library) }
                Spacer()
                shutter
                Spacer()
                if photos.isEmpty {
                    sideButton("text.cursor", title: "Describe") { finish(.describe) }
                } else {
                    Button { finish(.photos(photos)) } label: {
                        Text("Next")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.slate)
                            .frame(width: 72, height: 44)
                            .background(Theme.sand, in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 28)
        }
        .padding(.bottom, 12)
        .padding(.top, 14)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea())
    }

    private var shutter: some View {
        let full = photos.count >= MealCamera.limit
        return Button {
            Task { await shoot() }
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                Circle().fill(tint).frame(width: 64, height: 64)
                Image(systemName: "fork.knife").font(.title2.weight(.semibold)).foregroundStyle(.white)
            }
            .opacity(full ? 0.4 : 1)
        }
        .disabled(full || camera.busy || camera.status != .running)
        .accessibilityLabel(full ? "\(MealCamera.limit) photos, the most" : "Take photo")
    }

    private var denied: some View {
        VStack(spacing: 14) {
            message("Aide can't use the camera.", detail: "Allow it in Settings, or choose a photo instead.")
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.slate)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Theme.sand, in: Capsule())
        }
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline).foregroundStyle(.white)
            Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.7))
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.35), in: Circle())
        }
        .accessibilityLabel(label)
    }

    private func sideButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 48, height: 48)
                    .background(.white.opacity(0.16), in: Circle())
                Text(title).font(.caption2.weight(.medium))
            }
            .foregroundStyle(.white)
            .frame(width: 72)
        }
    }

    private func shoot() async {
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        withAnimation(.easeIn(duration: 0.25).delay(0.08)) { flash = false }
        guard let photo = await camera.capture() else { return }
        photos.append(photo)
    }

    private func finish(_ result: MealCameraResult) {
        done(result)
        dismiss()
    }
}

/// The capture session behind the meal camera: the back camera's preview, photos, the light, and the food barcodes
/// it sees (`AVCaptureMetadataOutput`, live, no Vision pass).
@MainActor
final class MealCamera: NSObject, ObservableObject {
    enum Status { case starting, running, denied, unavailable }

    /// Photos of one meal, as for the library.
    static let limit = 4
    static let barcodeTypes: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce, .code128]

    /// A back camera to use: none on the Simulator.
    static var isAvailable: Bool { AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil }

    @Published private(set) var status = Status.starting
    /// The food barcode in view, gone a moment after it leaves.
    @Published private(set) var barcode: String?
    @Published private(set) var torch = false
    @Published private(set) var busy = false
    private(set) var hasTorch = false

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let queue = DispatchQueue(label: "aide.mealcamera")
    private var device: AVCaptureDevice?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var pending: PhotoTaker?
    private var lastSeen = Date.distantPast
    private var forget: Task<Void, Never>?

    /// A barcode's digits when it's one a food packet carries; Code 128 only when it's all digits, EAN length.
    nonisolated static func foodCode(_ value: String?, type: AVMetadataObject.ObjectType) -> String? {
        guard let value, barcodeTypes.contains(type) else { return nil }
        let digits = value.filter(\.isNumber)
        if type == .code128 {
            guard digits.count == value.count, [8, 12, 13, 14].contains(digits.count) else { return nil }
        }
        return digits.count >= 6 ? digits : nil
    }

    func start() async {
        guard status == .starting else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { status = .denied; return }
        default:
            status = .denied
            return
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            status = .unavailable
            return
        }
        self.device = device
        hasTorch = device.hasTorch
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            metadataOutput.metadataObjectTypes = Self.barcodeTypes.filter(metadataOutput.availableMetadataObjectTypes.contains)
        }
        session.commitConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus), (try? device.lockForConfiguration()) != nil {
            device.focusMode = .continuousAutoFocus
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near } // plates, packets
            device.unlockForConfiguration()
        }
        let session = session
        await withCheckedContinuation { done in
            queue.async {
                session.startRunning()
                done.resume()
            }
        }
        status = .running
    }

    func stop() {
        forget?.cancel()
        if torch { toggleTorch() }
        let session = session
        queue.async { session.stopRunning() }
    }

    /// Keeps the preview and the photos upright as the phone turns.
    func attach(_ layer: AVCaptureVideoPreviewLayer) {
        guard let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotation = coordinator
        layer.connection?.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
    }

    func toggleTorch() {
        guard let device, device.hasTorch, (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = torch ? .off : .on
        device.unlockForConfiguration()
        torch.toggle()
    }

    /// One photo, shrunk like a library one, with any barcodes Vision reads in it; nil when it failed.
    func capture() async -> PickedPhoto? {
        guard status == .running, !busy else { return nil }
        busy = true
        defer { busy = false }
        if let angle = rotation?.videoRotationAngleForHorizonLevelCapture,
           let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        let image: UIImage? = await withCheckedContinuation { done in
            let taker = PhotoTaker { [weak self] image in
                self?.pending = nil
                done.resume(returning: image)
            }
            pending = taker
            photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: taker)
        }
        guard let image else { return nil }
        let (jpeg, codes) = await Task.detached {
            (PhotoPrep.jpeg(image), BarcodeReader.codes(in: image))
        }.value
        guard var photo = jpeg.flatMap(PickedPhoto.init(jpeg:)) else { return nil }
        photo.barcodes = codes
        if let seen = barcode, !photo.barcodes.contains(seen) { photo.barcodes.insert(seen, at: 0) }
        return photo
    }
}

extension MealCamera: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        let code = objects.lazy.compactMap { object -> String? in
            guard let readable = object as? AVMetadataMachineReadableCodeObject else { return nil }
            return Self.foodCode(readable.stringValue, type: readable.type)
        }.first
        guard let code else { return }
        MainActor.assumeIsolated {
            if barcode != code { barcode = code }
            lastSeen = Date()
            // Gone 1.5 s after it was last seen, so the pill doesn't flicker as the code slips in and out of focus.
            forget?.cancel()
            forget = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self, Date().timeIntervalSince(self.lastSeen) >= 1.4 else { return }
                self.barcode = nil
            }
        }
    }
}

/// One photo's delegate, kept alive by the camera until the photo is in.
private final class PhotoTaker: NSObject, AVCapturePhotoCaptureDelegate {
    private let done: (UIImage?) -> Void

    init(done: @escaping (UIImage?) -> Void) { self.done = done }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = error == nil ? photo.fileDataRepresentation().flatMap(UIImage.init(data:)) : nil
        DispatchQueue.main.async { self.done(image) }
    }
}

/// The live picture, filling its frame.
private struct MealCameraPreview: UIViewRepresentable {
    let camera: MealCamera

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.attach(view.previewLayer)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
