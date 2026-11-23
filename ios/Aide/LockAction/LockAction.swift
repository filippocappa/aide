import Foundation
import ManagedSettings

/// The shield's buttons (docs/API.md, "Rations"). On a ration's shield the first one spends one of today's opens:
/// the apps open, and stay open while they're used (LockMonitor locks them again once they've been closed the
/// ration's `gap`). The open goes to the server at once, so the Mac counts it too; the app sends any that didn't.
/// Every other shield's button just closes the app.
final class LockAction: ShieldActionDelegate {
    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        completionHandler(respond(action, LockBook.rationHolding(app: application), app: application))
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        completionHandler(respond(action, LockBook.rationHolding(domain: webDomain), domain: webDomain))
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        completionHandler(respond(action, LockBook.rationHolding(category: category), category: category))
    }

    private func respond(_ action: ShieldAction, _ ration: ScreenRation?, app: ApplicationToken? = nil,
                         category: ActivityCategoryToken? = nil, domain: WebDomainToken? = nil) -> ShieldActionResponse {
        guard action == .primaryButtonPressed, let ration,
              // A lock, a limit used up or the Focus filter still holds it: an open wouldn't show the app.
              LockBook.lockHolding(app: app, category: category, domain: domain) == nil,
              LockBook.limitHolding(app: app, category: category, domain: domain) == nil,
              LockBook.focusFilterHolding(app: app, category: category, domain: domain) == nil,
              LockBook.startRationOpen(ration.id) else { return .close }
        RationSender.send()
        return .defer
    }
}

/// Sends this phone's opens the server hasn't had, with the server's URL and token from the App Group's keychain.
enum RationSender {
    static func send() {
        guard let base = Keychain.get("serverURL").flatMap(URL.init(string:)), let token = Keychain.get("apiToken"),
              !token.isEmpty else { return }
        for open in LockBook.rationOpens where !open.sent {
            var req = URLRequest(url: base.appendingPathComponent("v1/rations/\(open.ration)/open"))
            req.httpMethod = "POST"
            req.timeoutInterval = 10
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "key": open.key, "device": "phone", "at": open.at, "granted": true,
            ])
            URLSession.shared.dataTask(with: req) { _, response, _ in
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                var opens = LockBook.rationOpens
                if let i = opens.firstIndex(where: { $0.key == open.key }) { opens[i].sent = true }
                LockBook.rationOpens = opens
            }.resume()
        }
    }
}
