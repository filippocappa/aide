import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share sheet's entry: finds the shared link and shows `ShareView` over the app it was shared from.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let model = ShareModel { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { await model.find(in: items) }
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum Stage: Equatable { case finding, ready, sending, sent, failed(String) }

    @Published var url: String?
    @Published var title: String?
    @Published var question = ""
    @Published var stage = Stage.finding
    let close: () -> Void
    private let api = APIClient(config: { AppSettings().apiConfig })

    init(close: @escaping () -> Void) { self.close = close }

    var isYouTube: Bool { url.map(ShareLinks.isYouTube) ?? false }

    /// A web URL, else the first link in shared text (the YouTube app shares both, Safari a URL).
    func find(in items: [NSExtensionItem]) async {
        let providers = items.flatMap { $0.attachments ?? [] }
        title = items.lazy.compactMap { $0.attributedContentText?.string }.first { !$0.isEmpty }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let u = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, u.scheme?.hasPrefix("http") == true {
                url = u.absoluteString
                break
            }
        }
        if url == nil {
            for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                   let link = ShareLinks.firstLink(in: text) {
                    url = link
                    break
                }
            }
        }
        if url == nil, let text = title { url = ShareLinks.firstLink(in: text) }
        stage = .ready
    }

    func send() async {
        guard let url, AppSettings().isConfigured else {
            stage = .failed("Set up the server in Aide's Settings first.")
            return
        }
        stage = .sending
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await api.startVideo(url, question: q.isEmpty ? nil : q)
            withAnimation(.snappy) { stage = .sent }
            try? await Task.sleep(for: .seconds(1.4))
            close()
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

}

/// A small card from the bottom: the link, what you want from it, and Send. Aide reads it in the background and the
/// brief comes as a notification, in a new chat with Aide.
struct ShareView: View {
    @ObservedObject var model: ShareModel
    @FocusState private var typing: Bool

    var body: some View {
        VStack {
            Spacer()
            card
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .background(Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { model.close() })
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Send to Aide", systemImage: "play.rectangle.fill")
                    .font(.headline)
                    .labelStyle(TintedIcon())
                Spacer()
                Button { model.close() } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.secondary.opacity(0.15), in: Circle())
                }
                .accessibilityLabel("Close")
            }
            switch model.stage {
            case .finding:
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            case .sent:
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                        .symbolEffect(.bounce, value: model.stage)
                    Text("Aide's on it").font(.title3.weight(.semibold))
                    Text("You'll get a notification when the brief is ready.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            default:
                form
            }
        }
        .padding(18)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 30, y: 10)
    }

    @ViewBuilder
    private var form: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = model.title, model.isYouTube {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
            }
            Text(model.url ?? "No link in what you shared.")
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        if model.url != nil && !model.isYouTube {
            Label("Only YouTube links for now.", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline).foregroundStyle(.orange)
        } else if model.url != nil {
            TextField("Anything in particular? (optional)", text: $model.question, axis: .vertical)
                .lineLimit(1...4)
                .focused($typing)
                .padding(12)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if case .failed(let why) = model.stage {
                Label(why, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
            }
            Button { Task { await model.send() } } label: {
                Group {
                    if model.stage == .sending { ProgressView().tint(Theme.onAccent) } else { Text("Send") }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.accent)
            .foregroundStyle(Theme.onAccent)
            .disabled(model.stage == .sending)
            Text("Aide reads it in the background and writes the brief in a new chat.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct TintedIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(.red)
            configuration.title
        }
    }
}
