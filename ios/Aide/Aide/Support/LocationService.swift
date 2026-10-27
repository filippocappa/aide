import CoreLocation
import UIKit

/// Where the phone is, for tram alerts (docs/API.md, "Transit (GTT)"): the server works out the walk to the stop.
/// A fix goes to the server when iOS reports a significant move (about 500 m, also with the app closed), when the
/// app comes to the foreground, and when a silent `location` push asks for one. With the app closed that needs
/// "Always"; with "While using", alerts use the last fix sent from the app.
/// While a tram's Live Activity is on, it follows the phone closely, in the background too, so the server can tell
/// when the user is at the stop or on the tram.
@MainActor
final class LocationService: NSObject, ObservableObject {
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var lastSent: Date? {
        didSet { UserDefaults.standard.set(lastSent, forKey: Keys.lastSent) }
    }
    @Published private(set) var lastError: String?

    private enum Keys {
        static let lastSent = "locationLastSent"
        static let askedAlways = "locationAskedAlways"
    }

    /// How long a `location` push waits for a fix; iOS gives a background push about 30 seconds.
    static let fixTimeout: Duration = .seconds(20)
    /// While following: a fix goes to the server this often, or after this far.
    static let followEvery: TimeInterval = 20
    static let followDistance: CLLocationDistance = 40

    /// A tram's Live Activity is on: location updates run, in the background too.
    private(set) var following = false
    private var lastFollowed: (at: Date, location: CLLocation)?

    private let manager = CLLocationManager()
    private let api: APIClient
    /// `location` pushes waiting for the next fix to reach the server.
    private var waiting: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(api: APIClient) {
        self.api = api
        authorization = manager.authorizationStatus
        lastSent = UserDefaults.standard.object(forKey: Keys.lastSent) as? Date
        super.init()
        manager.delegate = self
        // A hundred metres is plenty for the walk to a stop, and comes quickly.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isOn: Bool { authorization == .authorizedAlways || authorization == .authorizedWhenInUse }
    var isAlways: Bool { authorization == .authorizedAlways }

    /// iOS shows the "Always" question once; after that only iOS Settings can change it.
    var canAsk: Bool {
        authorization == .notDetermined
            || (authorization == .authorizedWhenInUse && !UserDefaults.standard.bool(forKey: Keys.askedAlways))
    }

    /// Launch. iOS relaunches the app for a significant move only if monitoring starts again here.
    func start() {
        guard isAlways else { return }
        manager.startMonitoringSignificantLocationChanges()
    }

    /// Return to the app: one fresh fix.
    func refresh() {
        if isOn { manager.requestLocation() }
    }

    /// The first time, iOS offers "While using"; picked, the app may ask for "Always" once more.
    func requestAccess() {
        if authorization == .authorizedWhenInUse { UserDefaults.standard.set(true, forKey: Keys.askedAlways) }
        manager.requestAlwaysAuthorization()
    }

    /// Close updates while a tram's Live Activity is on (docs/API.md, "Location"), off when the last one ends.
    func follow(_ on: Bool) {
        guard on != following, !on || isOn else { return }
        following = on
        if on {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.pausesLocationUpdatesAutomatically = false
            manager.activityType = .otherNavigation
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = 10
            lastFollowed = nil
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = kCLDistanceFilterNone
        }
    }

    /// While following, every update comes here: only one per `followEvery` or `followDistance` goes on.
    private func worthSending(_ location: CLLocation) -> Bool {
        guard following, waiting.isEmpty, let last = lastFollowed else {
            lastFollowed = (Date(), location)
            return true
        }
        guard Date().timeIntervalSince(last.at) >= Self.followEvery
                || location.distance(from: last.location) >= Self.followDistance else { return false }
        lastFollowed = (Date(), location)
        return true
    }

    /// A silent `location` push: a fresh fix to the server, or false within `fixTimeout`.
    func sendFresh() async -> Bool {
        guard isOn else { return false }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiting[id] = continuation
            manager.requestLocation()
            Task {
                try? await Task.sleep(for: Self.fixTimeout)
                waiting.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }

    private func finish(_ ok: Bool) {
        let all = waiting
        waiting = [:]
        all.values.forEach { $0.resume(returning: ok) }
    }

    private func send(_ location: CLLocation) async -> Bool {
        guard location.horizontalAccuracy >= 0 else { return false }
        // A significant move can wake the app in the background with seconds to spare: finish the upload.
        let task = UIApplication.shared.beginBackgroundTask(withName: "location")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        let fix = LocationFix(lat: location.coordinate.latitude, lon: location.coordinate.longitude,
                              accuracy: location.horizontalAccuracy, at: Wire.utc(location.timestamp))
        do {
            try await api.sendLocation(fix)
            lastSent = Date()
            lastError = nil
            return true
        } catch APIError.notConfigured {
            return false
        } catch APIError.server(let status, _) where status == 404 {
            lastError = "The server doesn't take the location yet."
        } catch {
            lastError = error.localizedDescription
        }
        return false
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            let was = authorization
            authorization = status
            guard status != was else { return }
            start()
            refresh()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in
            guard worthSending(last) else { return }
            finish(await send(last))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // `locationUnknown` passes: iOS keeps trying, and a one-shot request ends with it.
        let unknown = (error as? CLError)?.code == .locationUnknown
        Task { @MainActor in
            if !unknown { lastError = "No location: \(error.localizedDescription)" }
            finish(false)
        }
    }
}
