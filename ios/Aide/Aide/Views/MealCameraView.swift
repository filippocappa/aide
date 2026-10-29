@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// What the meal camera ends with; Health → Food carries it out once the camera has gone.
enum MealCameraResult {
    case photos([PickedPhoto])
    /// A packet logged from its barcode, on the page the camera opened.
    case logged(Meal)
    case library
    case describe
}

/// Aide's own camera for logging a meal: a few shots of the plate (up to `MealCamera.limit`), or a packet: once a
/// food barcode holds still in view, its page opens over the camera by itself (`ScanSheet`, no model call), and
/// Cancel there comes back to the camera. The lenses as in the Camera app (0.5×, 1×, 2×, the telephoto), pinch to
/// zoom, tap to focus, and macro on its own up close (the phone's virtual camera switches lens like the Camera app).
/// The library and "Describe" are a tap away. Chat photos keep the system camera (`CameraPicker`).
struct MealCameraView: View {
    let tint: Color
    /// The day a packet is logged on; nil is today.
    var date: String?
    let done: (MealCameraResult) -> Void

    @StateObject private var camera = MealCamera()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var photos: [PickedPhoto] = []
    @State private var flash = false
    /// Where a tap focused, for the ring drawn there a moment.
    @State private var focusAt: CGPoint?
    /// The packet whose page is open, and the photo taken as it opened (for "ask Coach").
    @State private var scanning: ScannedCode?
    @State private var scanCode: String?
    @State private var scanPhoto: PickedPhoto?
    @State private var scanLogged: Meal?
    @State private var scanToCoach = false
    /// A barcode whose page was cancelled: not opened again by itself until it leaves the picture (the pill opens it).
    @State private var ignored: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch camera.status {
            case .denied:
                denied
            case .unavailable:
                message("No camera here.", detail: "Choose a photo instead.")
            case .failed:
                retry("The camera didn't start.")
            case .starting where camera.slow:
                retry("The camera is taking a while.")
            case .starting:
                EmptyView()
            case .running: // only now: the preview keeps itself upright from the camera's device
                MealCameraPreview(camera: camera) { point in
                    focusAt = point
                    Task {
                        try? await Task.sleep(for: .seconds(0.9))
                        if focusAt == point { focusAt = nil }
                    }
                }
                .ignoresSafeArea()
                .overlay(Color.white.opacity(flash ? 0.7 : 0).ignoresSafeArea().allowsHitTesting(false))
                .overlay { focusRing }
                .overlay {
                    if let paused = camera.paused {
                        message("Camera paused", detail: paused)
                            .padding(.vertical, 16)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
                .transition(.opacity)
            }
            if camera.status == .running || camera.status == .starting {
                viewfinder.allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                topBar
                Spacer()
                if let code = camera.barcode, code == ignored, photos.isEmpty, scanning == nil {
                    barcodePill(code)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        .padding(.bottom, 16)
                }
                bottom
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .animation(.easeOut(duration: 0.25), value: camera.status)
        .animation(.spring(duration: 0.3), value: camera.barcode)
        .animation(.easeOut(duration: 0.2), value: photos)
        .animation(.easeOut(duration: 0.2), value: camera.macro)
        .sensoryFeedback(.success, trigger: scanning?.code) { _, new in new != nil }
        .sensoryFeedback(.selection, trigger: camera.lens)
        .task { await camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.resume() } // back from Control Center or another app
        }
        .onChange(of: camera.steady) { _, code in
            guard let code, code != ignored, photos.isEmpty, scanning == nil else { return }
            open(code)
        }
        .onChange(of: camera.barcode) { _, code in
            if code == nil { ignored = nil }
        }
        .sheet(item: $scanning, onDismiss: afterScan) { code in
            ScanSheet(barcode: code.code, date: date, tint: tint, logged: { scanLogged = $0 },
                      askCoach: { scanToCoach = true })
        }
    }

    /// The packet's page over the camera, with a photo of it taken on the way (Coach gets it if it's a whole meal).
    private func open(_ code: String) {
        scanPhoto = nil
        scanCode = code
        scanning = ScannedCode(code: code)
        Task { scanPhoto = await camera.capture() }
    }

    private func afterScan() {
        if let meal = scanLogged {
            finish(.logged(meal))
        } else if scanToCoach, let photo = scanPhoto {
            finish(.photos([photo]))
        } else {
            ignored = scanCode
        }
        scanCode = nil
        scanLogged = nil
        scanToCoach = false
        scanPhoto = nil
    }

    // MARK: Over the picture

    /// Four corners in the middle: a square for the plate, a wide box in the sand colour once a barcode is in view.
    private var viewfinder: some View {
        GeometryReader { geo in
            let side = min(geo.size.width * 0.74, 320)
            let seen = camera.barcode != nil && photos.isEmpty
            VStack(spacing: 12) {
                Corners()
                    .stroke(seen ? Theme.sand : .white.opacity(0.85),
                            style: StrokeStyle(lineWidth: seen ? 4 : 3, lineCap: .round))
                    .frame(width: side, height: seen ? side * 0.55 : side)
                    .shadow(color: .black.opacity(0.25), radius: 6)
                Text(seen ? "Barcode" : " ")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.slate)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.sand, in: Capsule())
                    .opacity(seen ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: -24)
        }
    }

    @ViewBuilder
    private var focusRing: some View {
        if let focusAt {
            GeometryReader { _ in
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.sand, lineWidth: 1.5)
                    .frame(width: 72, height: 72)
                    .position(focusAt)
                    .transition(.scale(scale: 1.4).combined(with: .opacity))
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack {
                glassButton("xmark", label: "Close") { dismiss() }
                Spacer()
                if camera.macro {
                    Label("Macro", systemImage: "camera.macro")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.sand)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.opacity)
                }
                Spacer()
                if camera.hasTorch {
                    glassButton(camera.torch ? "bolt.fill" : "bolt.slash.fill", label: camera.torch ? "Light off" : "Light on",
                                on: camera.torch) {
                        camera.toggleTorch()
                    }
                } else {
                    Color.clear.frame(width: 42, height: 42)
                }
            }
            Text(photos.isEmpty ? "Your plate, or a packet's barcode"
                 : "\(photos.count) of \(MealCamera.limit) · another angle, or Next")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.5), radius: 4)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// "Barcode 8001505005707 · Open": the packet's page again, after it was cancelled with the packet still in view.
    private func barcodePill(_ code: String) -> some View {
        Button {
            ignored = nil
            open(code)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "barcode.viewfinder")
                Text(code).monospacedDigit()
                Text("·").foregroundStyle(Theme.slate.opacity(0.6))
                Text("Open").fontWeight(.bold)
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

    // MARK: The bottom

    private var bottom: some View {
        VStack(spacing: 18) {
            if !photos.isEmpty { strip }
            if camera.lenses.count > 1 { lensPicker }
            HStack(alignment: .center) {
                sideButton("photo.on.rectangle.angled", title: "Library") { finish(.library) }
                Spacer()
                shutter
                Spacer()
                if photos.isEmpty {
                    sideButton("text.bubble", title: "Describe") { finish(.describe) }
                } else {
                    Button { finish(.photos(photos)) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "arrow.right")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(Theme.slate)
                                .frame(width: 54, height: 54)
                                .background(Theme.sand, in: Circle())
                            Text("Next").font(.caption.weight(.semibold)).foregroundStyle(.white)
                        }
                        .frame(width: 76)
                    }
                    .accessibilityLabel("Next: \(photos.count) photos")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 24)
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    /// The shots so far; a tap takes one out.
    private var strip: some View {
        HStack(spacing: 8) {
            ForEach(photos) { photo in
                Button { photos.removeAll { $0.id == photo.id } } label: {
                    Image(uiImage: photo.preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.8), lineWidth: 1.5))
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.white, .black.opacity(0.7))
                                .offset(x: 5, y: -5)
                        }
                }
                .accessibilityLabel("Remove this photo")
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    /// 0.5 · 1× · 2 · 5, as in the Camera app: the chosen one larger with its ×, or the pinch's zoom on the nearest.
    private var lensPicker: some View {
        HStack(spacing: 6) {
            ForEach(camera.lenses) { lens in
                let on = camera.lens == lens.id
                Button { camera.zoom(to: lens.factor, ramp: true) } label: {
                    Text(on ? camera.zoomLabel : lens.label)
                        .font(.system(size: on ? 13 : 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(on ? Theme.sand : .white)
                        .frame(width: on ? 40 : 32, height: on ? 40 : 32)
                        .background(.black.opacity(on ? 0.55 : 0.4), in: Circle())
                }
                .accessibilityLabel("\(lens.label) times")
            }
        }
        .padding(5)
        .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
        .animation(.snappy(duration: 0.2), value: camera.lens)
    }

    private var shutter: some View {
        let full = photos.count >= MealCamera.limit
        return Button {
            Task { await shoot() }
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 5).frame(width: 80, height: 80)
                Circle().fill(.white).frame(width: 66, height: 66)
            }
            .opacity(full ? 0.35 : 1)
        }
        .buttonStyle(ShutterStyle())
        .disabled(full || camera.busy || camera.status != .running)
        .accessibilityLabel(full ? "\(MealCamera.limit) photos, the most" : "Take photo")
    }

    private var denied: some View {
        VStack(spacing: 14) {
            message("Aide can't use the camera.", detail: "Allow it in Settings, or choose a photo instead.")
            sandButton("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        }
    }

    private func retry(_ title: String) -> some View {
        VStack(spacing: 14) {
            message(title, detail: "Try again, or choose a photo instead.")
            sandButton("Try again") { Task { await camera.start() } }
        }
    }

    private func sandButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.slate)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Theme.sand, in: Capsule())
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline).foregroundStyle(.white)
            Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.7))
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }

    private func glassButton(_ symbol: String, label: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(on ? Theme.slate : .white)
                .frame(width: 42, height: 42)
                .background {
                    if on { Circle().fill(Theme.sand) } else { Circle().fill(.ultraThinMaterial) }
                }
        }
        .accessibilityLabel(label)
    }

    private func sideButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 54, height: 54)
                    .background(.ultraThinMaterial, in: Circle())
                Text(title).font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 76)
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

/// The shutter shrinks a little under the finger.
private struct ShutterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A viewfinder's four corners.
private struct Corners: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = min(rect.width, rect.height) * 0.16
        let r: CGFloat = 14
        var p = Path()
        // Top left, top right, bottom right, bottom left: an arm along each edge from a rounded corner.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        p.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
        p.move(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - arm))
        return p
    }
}

/// The capture session behind the meal camera: the back camera's preview, photos, the light, the lenses, and the
/// food barcodes it sees (`AVCaptureMetadataOutput`, live, no Vision pass).
@MainActor
final class MealCamera: NSObject, ObservableObject {
    enum Status { case starting, running, denied, unavailable, failed }

    /// A lens button: its label ("0.5", "1", "2", "5") and the device's zoom factor for it.
    struct Lens: Identifiable, Equatable {
        let label: String
        let factor: CGFloat
        var id: String { label }
    }

    /// Photos of one meal, as for the library.
    static let limit = 4
    static let barcodeTypes: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce, .code128]
    /// The back camera, best first: the virtual ones switch lens on their own (macro up close), like the Camera app.
    static let deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera,
                                                            .builtInDualCamera, .builtInWideAngleCamera]

    /// A back camera to use: none on the Simulator.
    static var isAvailable: Bool { backCamera() != nil }

    static func backCamera() -> AVCaptureDevice? {
        deviceTypes.lazy.compactMap { AVCaptureDevice.default($0, for: .video, position: .back) }.first
    }

    @Published private(set) var status = Status.starting
    /// The food barcode in view, gone a moment after it leaves.
    @Published private(set) var barcode: String?
    /// The barcode once it has been read the same for a moment (`steadyAfter`), so a code glimpsed in passing
    /// doesn't open a page; nil again when it leaves.
    @Published private(set) var steady: String?
    static let steadyAfter: TimeInterval = 0.35
    @Published private(set) var torch = false
    @Published private(set) var busy = false
    /// Still starting after a few seconds: the view offers Try again.
    @Published private(set) var slow = false
    /// Why iOS has paused the camera (another app has it, the app is in the background…); nil while it runs.
    @Published private(set) var paused: String?
    /// The lens buttons this phone has, the one nearest the zoom, and the zoom as the Camera app says it ("1.4×").
    @Published private(set) var lenses: [Lens] = []
    @Published private(set) var lens: String?
    @Published private(set) var zoomLabel = "1×"
    /// The ultra wide is on at 1× or more: the phone switched to it for a close-up.
    @Published private(set) var macro = false
    private(set) var hasTorch = false

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let queue = DispatchQueue(label: "aide.mealcamera")
    private var device: AVCaptureDevice?
    /// The zoom factor that is "1×": the wide lens, past the ultra wide's range on a virtual camera.
    private var base: CGFloat = 1
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var observations: [NSKeyValueObservation] = []
    private var pending: PhotoTaker?
    private var lastSeen = Date.distantPast
    private var firstSeen = Date.distantPast
    private var forget: Task<Void, Never>?
    private var watchers: [NSObjectProtocol] = []
    /// `Library/Caches/camera.log`, pulled like the voice one (`Support/VoiceLog.swift`).
    nonisolated static let log = Diary(name: "camera")

    override init() {
        super.init()
        let center = NotificationCenter.default
        watchers = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { note in
                let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int)
                    .flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
                MainActor.assumeIsolated { self.interrupted(reason) }
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { _ in
                MainActor.assumeIsolated {
                    Self.log.note("interruption ended")
                    self.paused = nil
                }
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                MainActor.assumeIsolated {
                    Self.log.note("runtime error: \(error.map { String(describing: $0) } ?? "?")")
                    self.resume()
                }
            },
        ]
    }

    deinit {
        watchers.forEach(NotificationCenter.default.removeObserver)
    }

    private func interrupted(_ reason: AVCaptureSession.InterruptionReason?) {
        Self.log.note("interrupted: \(reason.map { String($0.rawValue) } ?? "?")")
        paused = switch reason {
        case .videoDeviceInUseByAnotherClient: "Another app is using the camera."
        case .videoDeviceNotAvailableWithMultipleForegroundApps: "The camera is off while another app is on screen too."
        case .videoDeviceNotAvailableDueToSystemPressure: "The phone is too warm for the camera right now."
        default: "It comes back when Aide is in front again."
        }
    }

    /// A barcode's digits when it's one a food packet carries; Code 128 only when it's all digits, EAN length.
    nonisolated static func foodCode(_ value: String?, type: AVMetadataObject.ObjectType) -> String? {
        guard let value, barcodeTypes.contains(type) else { return nil }
        let digits = value.filter(\.isNumber)
        if type == .code128 {
            guard digits.count == value.count, [8, 12, 13, 14].contains(digits.count) else { return nil }
        }
        return digits.count >= 6 ? digits : nil
    }

    /// The lens buttons for a camera: the ultra wide (0.5), the wide (1), 2× (the wide's middle) and the telephoto,
    /// as zoom factors of the device. `switchOvers` are where a virtual camera changes lens; `kinds` what it has.
    nonisolated static func lenses(kinds: Set<AVCaptureDevice.DeviceType>, switchOvers: [CGFloat], maxZoom: CGFloat)
        -> (base: CGFloat, lenses: [Lens]) {
        let ultraWide = kinds.contains(.builtInUltraWideCamera)
        let tele = kinds.contains(.builtInTelephotoCamera)
        let base = ultraWide ? (switchOvers.first ?? 2) : 1
        var out: [Lens] = []
        if ultraWide { out.append(Lens(label: "0.5", factor: 1)) }
        out.append(Lens(label: "1", factor: base))
        let teleFactor = tele ? switchOvers.last : nil
        if base * 2 <= maxZoom, teleFactor.map({ $0 > base * 2.5 }) ?? true { out.append(Lens(label: "2", factor: base * 2)) }
        if let teleFactor, teleFactor <= maxZoom {
            out.append(Lens(label: Double(teleFactor / base).formatted(.number.precision(.fractionLength(0...1))), factor: teleFactor))
        }
        return (base, out)
    }

    /// Asks for the camera, sets the session up and starts it, all of it on the session's own queue (Apple's way;
    /// `startRunning` blocks). Again from Try again, when the first go failed.
    func start() async {
        guard status == .starting || status == .failed else { return }
        status = .starting
        slow = false
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        Self.log.note("start: access \(auth.rawValue), \(session.inputs.count) inputs")
        switch auth {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { status = .denied; return }
        default:
            status = .denied
            return
        }
        guard let device = device ?? Self.backCamera() else {
            status = .unavailable
            return
        }
        let input: AVCaptureDeviceInput?
        do {
            input = session.inputs.isEmpty ? try AVCaptureDeviceInput(device: device) : nil
        } catch {
            Self.log.note("no input: \(error)")
            status = .failed
            return
        }
        self.device = device
        hasTorch = device.hasTorch
        metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.status == .starting else { return }
            Self.log.note("still starting after 4 s")
            self.slow = true
        }
        defer { watchdog.cancel() }
        let (session, photoOutput, metadataOutput, types) = (session, photoOutput, metadataOutput, Self.barcodeTypes)
        let running: Bool = await withCheckedContinuation { done in
            queue.async {
                if let input {
                    session.beginConfiguration()
                    session.sessionPreset = .photo
                    if session.canAddInput(input) { session.addInput(input) }
                    if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
                    if session.canAddOutput(metadataOutput) {
                        session.addOutput(metadataOutput)
                        metadataOutput.metadataObjectTypes = types.filter(metadataOutput.availableMetadataObjectTypes.contains)
                    }
                    session.commitConfiguration()
                }
                if !session.isRunning { session.startRunning() }
                done.resume(returning: session.isRunning)
            }
        }
        Self.log.note("running: \(running), \(device.deviceType.rawValue), \(session.outputs.count) outputs")
        guard running else {
            status = .failed
            return
        }
        setUpLenses(device)
        status = .running
    }

    /// The lens buttons, 1× to start with, macro left to the phone, focus on what's near.
    private func setUpLenses(_ device: AVCaptureDevice) {
        let kinds = Set(device.constituentDevices.map(\.deviceType) + [device.deviceType])
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        (base, lenses) = Self.lenses(kinds: kinds, switchOvers: switchOvers, maxZoom: device.maxAvailableVideoZoomFactor)
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isVirtualDevice, device.activePrimaryConstituentDeviceSwitchingBehavior != .unsupported {
            device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
        }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        device.videoZoomFactor = min(max(base, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        device.unlockForConfiguration()
        observations.append(device.observe(\.videoZoomFactor, options: [.initial, .new]) { [weak self] device, _ in
            let factor = device.videoZoomFactor
            DispatchQueue.main.async { self?.zoomed(factor) }
        })
        observations.append(device.observe(\.activePrimaryConstituent, options: [.initial, .new]) { [weak self] device, _ in
            let ultraWide = device.activePrimaryConstituent?.deviceType == .builtInUltraWideCamera
            let factor = device.videoZoomFactor
            DispatchQueue.main.async {
                guard let self else { return }
                self.macro = ultraWide && factor >= self.base * 0.99
            }
        })
        Self.log.note("lenses: \(lenses.map(\.label)), base \(base), switch-overs \(switchOvers)")
    }

    private func zoomed(_ factor: CGFloat) {
        let shown = factor / base
        zoomLabel = (shown < 1 ? Double(shown).formatted(.number.precision(.fractionLength(1)))
                     : Double(shown).formatted(.number.precision(.fractionLength(0...1)))) + "×"
        lens = lenses.last(where: { $0.factor <= factor * 1.001 })?.id ?? lenses.first?.id
        macro = device?.activePrimaryConstituent?.deviceType == .builtInUltraWideCamera && factor >= base * 0.99
    }

    /// To a lens (ramped, like the Camera app) or a pinch's factor (at once), within what the device can do: up to
    /// 10× past the wide.
    func zoom(to factor: CGFloat, ramp: Bool = false) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let factor = min(max(factor, device.minAvailableVideoZoomFactor), min(device.maxAvailableVideoZoomFactor, base * 10))
        if ramp {
            device.ramp(toVideoZoomFactor: factor, withRate: 12)
        } else {
            device.cancelVideoZoomRamp()
            device.videoZoomFactor = factor
        }
    }

    var zoomFactor: CGFloat { device?.videoZoomFactor ?? 1 }

    /// Focus and exposure on a point of the picture (0–1, the device's own coordinates), then keep following it.
    func focus(at point: CGPoint) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = point
            device.focusMode = device.isFocusModeSupported(.continuousAutoFocus) ? .continuousAutoFocus : .autoFocus
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = point
            device.exposureMode = .continuousAutoExposure
        }
    }

    /// Starts the session again when it stopped under us (a runtime error, back from the background).
    func resume() {
        guard status == .running else { return }
        let session = session
        queue.async {
            guard !session.isRunning else { return }
            session.startRunning()
            let running = session.isRunning
            Task { @MainActor in Self.log.note("resumed: \(running)") }
        }
    }

    func stop() {
        forget?.cancel()
        if torch { toggleTorch() }
        let session = session
        queue.async { session.stopRunning() }
    }

    /// Keeps the preview upright as the phone turns: the coordinator's angle, followed as it changes (it's only right
    /// once the layer is on screen).
    func attach(_ layer: AVCaptureVideoPreviewLayer) {
        guard let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotation = coordinator
        observations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak layer] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                guard let connection = layer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
        })
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
        guard let image else {
            Self.log.note("no photo (session running: \(session.isRunning))")
            return nil
        }
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
            let now = Date()
            if barcode != code {
                barcode = code
                steady = nil
                firstSeen = now
            } else if steady != code, now.timeIntervalSince(firstSeen) >= Self.steadyAfter {
                steady = code
            }
            lastSeen = now
            // Gone 1.5 s after it was last seen, so the pill doesn't flicker as the code slips in and out of focus.
            forget?.cancel()
            forget = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self, Date().timeIntervalSince(self.lastSeen) >= 1.4 else { return }
                self.barcode = nil
                self.steady = nil
            }
        }
    }
}

/// One photo's delegate, kept alive by the camera until the photo is in.
private final class PhotoTaker: NSObject, AVCapturePhotoCaptureDelegate {
    private let done: (UIImage?) -> Void

    init(done: @escaping (UIImage?) -> Void) { self.done = done }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { MealCamera.log.note("photo failed: \(error)") }
        let image = error == nil ? photo.fileDataRepresentation().flatMap(UIImage.init(data:)) : nil
        DispatchQueue.main.async { self.done(image) }
    }
}

/// The live picture, filling its frame: tap to focus there (`focused` gets the point, for the ring), pinch to zoom.
private struct MealCameraPreview: UIViewRepresentable {
    let camera: MealCamera
    let focused: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(camera: camera, focused: focused) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.attach(view.previewLayer)
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap)))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch)))
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        let camera: MealCamera
        let focused: (CGPoint) -> Void
        private var pinchStart: CGFloat = 1

        init(camera: MealCamera, focused: @escaping (CGPoint) -> Void) {
            self.camera = camera
            self.focused = focused
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PreviewView else { return }
            let point = gesture.location(in: view)
            camera.focus(at: view.previewLayer.captureDevicePointConverted(fromLayerPoint: point))
            focused(point)
        }

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { pinchStart = camera.zoomFactor }
            camera.zoom(to: pinchStart * gesture.scale)
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
