import SwiftUI

// An errand drawn by the app, not the site (docs/API.md, "Live view", the scene): what kind of page Aide is on and
// the few real things on it (the results with their pictures and prices, the product, the cart), with a cursor
// that goes where Aide does. And the app's own screen for logging in, codes and CAPTCHAs, which types into the page
// for you. The real page stays a tap away (the card's menu, the sheet's footnote) for what these don't cover.

/// What kind of page the errand is on and what's on it: the socket's `scene`.
struct PageScene: Decodable, Equatable {
    /// results, product, cart, checkout, confirmation, login, code, captcha, page
    let kind: String
    var site: String?
    var title: String?
    var url: String?
    var icon: String?
    var query: String?
    var items: [Item]
    var product: Shown?
    var cart: Cart?
    var form: Fields?
    var captcha: Captcha?
    /// On a page that isn't a login: its "Accedi" / "Log in", to go to the login.
    var signin: String?

    struct Item: Decodable, Equatable, Identifiable {
        let title: String
        var price: String?
        var image: String?
        let ref: String
        var id: String { ref }
    }

    struct Shown: Decodable, Equatable {
        let title: String
        var price: String?
        var image: String?
        var rating: Double?
    }

    struct Cart: Decodable, Equatable {
        var count: Int?
        var total: String?
    }

    struct Fields: Decodable, Equatable {
        var fields: [Field]
        var submit: Choice?
        var choices: [Choice]
        var remember: String?
        var remembered: Bool?
        var error: String?
    }

    struct Field: Decodable, Equatable, Identifiable {
        let ref: String
        /// username, password, code, phone, text
        let kind: String
        var label: String?
        var filled: Bool
        var id: String { ref }
    }

    struct Choice: Decodable, Equatable, Identifiable {
        let ref: String
        var text: String?
        var id: String { ref }
    }

    struct Captcha: Decodable, Equatable {
        /// text (characters to type), grid, checkbox, other (tapped on its picture)
        let kind: String
        let ref: String
        var inputRef: String?
        var submitRef: String?
    }

    /// A login, a code or a CAPTCHA: the user's part, on the app's own screen.
    var isYourTurn: Bool { ["login", "code", "captcha"].contains(kind) }
    var siteName: String { site ?? url.flatMap { URL(string: $0)?.host() } ?? "the site" }
    var iconURL: URL? { icon.flatMap(URL.init(string:)) }

    var turnTitle: String {
        switch kind {
        case "code": "A code from \(siteName)"
        case "captcha": "\(siteName) checks you're human"
        default: "Log in to \(siteName)"
        }
    }

    var turnButton: String {
        switch kind {
        case "code": "Enter the code"
        case "captcha": "Solve it"
        default: "Log in"
        }
    }

    var turnSymbol: String {
        switch kind {
        case "code": "ellipsis.rectangle.fill"
        case "captcha": "checkmark.shield.fill"
        default: "lock.fill"
        }
    }

    /// The result Aide just tapped, from what the tap was on (a tile's link carries its name).
    func item(clicked action: BrowserLive.Action?) -> Item? {
        guard let action, action.kind == "click", let label = action.label?.lowercased(), label.count >= 4 else {
            return nil
        }
        return items.first { item in
            let title = item.title.lowercased()
            return title.hasPrefix(String(label.prefix(24))) || label.hasPrefix(String(title.prefix(24)))
        }
    }
}

// MARK: - The stage

/// The errand, drawn: a slim browser bar (the site, its cart, a live dot) over a screen of Aide's own for the kind
/// of page it's on. A new page slides in (back slides it the other way); a result Aide taps lights up first.
struct ErrandStage: View {
    let scene: PageScene?
    let action: BrowserLive.Action?
    let tint: Color
    /// Waiting for your Confirm (on the checkout).
    var confirming = false
    /// In the full sheet: more results, bigger pictures.
    var large = false
    /// On a login, a code or a CAPTCHA: opens the app's own screen for it.
    var yourTurn: (() -> Void)?

    @State private var shown: PageScene?
    @State private var picked: String?
    @State private var forward = true

    var body: some View {
        VStack(spacing: 0) {
            StageBar(scene: shown, tint: tint, live: scene != nil)
            ZStack {
                content
                    .id(key)
                    .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .background(Theme.background)
        .onAppear { shown = scene }
        .onChange(of: scene) { _, new in advance(to: new) }
    }

    private var key: String { shown.map { "\($0.kind)|\($0.url ?? "")" } ?? "loading" }

    /// The next scene; after a tap on a result, that result lights up for a moment first.
    private func advance(to new: PageScene?) {
        guard let new else { return }
        let samePage = new.kind == shown?.kind && new.url == shown?.url
        if !samePage, let tile = shown?.item(clicked: action) {
            withAnimation(.spring(duration: 0.3)) { picked = tile.ref }
            Task {
                try? await Task.sleep(for: .milliseconds(650))
                move(to: new)
            }
        } else {
            move(to: new)
        }
    }

    private func move(to new: PageScene) {
        forward = action?.kind != "back"
        withAnimation(.spring(duration: 0.5)) {
            shown = new
            picked = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if let s = shown {
            switch s.kind {
            case "results": ResultsStage(scene: s, picked: picked, tint: tint, large: large)
            case "product": ProductStage(scene: s, action: action, tint: tint)
            case "cart", "checkout": CartStage(scene: s, confirming: confirming, tint: tint)
            case "confirmation": DoneStage(text: "Order placed", tint: tint)
            case "login", "code", "captcha": TurnStage(scene: s, tint: tint, open: yourTurn)
            default: PageStage(scene: s, action: action, tint: tint)
            }
        } else {
            SkeletonStage()
        }
    }
}

private struct StageBar: View {
    let scene: PageScene?
    let tint: Color
    let live: Bool
    @State private var bump = false

    var body: some View {
        HStack(spacing: 8) {
            SiteIcon(url: scene?.iconURL, size: 18)
            Text(scene?.siteName ?? "Opening…")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let count = scene?.cart?.count, count > 0 {
                Label("\(count)", systemImage: "cart.fill")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(tint.opacity(0.2), in: Capsule())
                    .scaleEffect(bump ? 1.3 : 1)
            }
            LiveDot(on: live, tint: tint)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.chip.opacity(0.6))
        .onChange(of: scene?.cart?.count) { old, new in
            guard (new ?? 0) > (old ?? 0) else { return }
            withAnimation(.spring(duration: 0.25)) { bump = true }
            withAnimation(.spring(duration: 0.4).delay(0.25)) { bump = false }
        }
    }
}

/// The site's icon, or a globe.
struct SiteIcon: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "globe").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.secondary)
                    .padding(size * 0.1)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct LiveDot: View {
    let on: Bool
    let tint: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(on ? tint : Color.secondary)
            .frame(width: 7, height: 7)
            .background(Circle().fill(tint.opacity(on ? 0.35 : 0)).scaleEffect(pulse ? 2.6 : 1).opacity(pulse ? 0 : 1))
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
            }
            .accessibilityHidden(true)
    }
}

// MARK: Scenes

private struct ResultsStage: View {
    let scene: PageScene
    let picked: String?
    let tint: Color
    let large: Bool
    @State private var arrived = 0
    @State private var looking = 0
    @Namespace private var cursor

    var body: some View {
        let tiles = Array(scene.items.prefix(large ? 6 : 4))
        VStack(alignment: .leading, spacing: 10) {
            SearchPill(query: scene.query ?? scene.title ?? "", tint: tint)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                if tiles.isEmpty {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.chip).frame(height: 118)
                            .shimmering()
                    }
                }
                ForEach(Array(tiles.enumerated()), id: \.element.id) { i, tile in
                    let lit = picked == tile.ref || (picked == nil && arrived >= tiles.count && looking % tiles.count == i)
                    StageTile(item: tile, lit: lit, chosen: picked == tile.ref, tint: tint,
                              pictureHeight: large ? 120 : 58)
                        .overlay(alignment: .bottomTrailing) {
                            if lit {
                                Cursor(tint: tint, pressing: picked == tile.ref)
                                    .matchedGeometryEffect(id: "cursor", in: cursor)
                                    .offset(x: -8, y: -8)
                            }
                        }
                        .opacity(i < arrived ? 1 : 0)
                        .offset(y: i < arrived ? 0 : 14)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .task(id: tiles.map(\.ref)) {
            arrived = 0
            for i in 0..<tiles.count {
                try? await Task.sleep(for: .milliseconds(140))
                withAnimation(.spring(duration: 0.4)) { arrived = i + 1 }
            }
            // Then Aide looks them over, one after another.
            while !Task.isCancelled && !tiles.isEmpty {
                try? await Task.sleep(for: .seconds(1.3))
                withAnimation(.spring(duration: 0.55)) { looking += 1 }
            }
        }
    }
}

private struct SearchPill: View {
    let query: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(tint)
            TypingText(text: query).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.chip, in: Capsule())
    }
}

/// Text that types itself out, letter by letter.
private struct TypingText: View {
    let text: String
    @State private var count = 0

    var body: some View {
        (Text(String(text.prefix(count))) + Text(count < text.count ? "▏" : "").foregroundStyle(.secondary))
            .task(id: text) {
                count = 0
                for i in 0...text.count {
                    count = i
                    try? await Task.sleep(for: .milliseconds(45))
                }
            }
    }
}

private struct StageTile: View {
    let item: PageScene.Item
    let lit: Bool
    let chosen: Bool
    let tint: Color
    let pictureHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StagePicture(url: item.image)
                .frame(maxWidth: .infinity)
                .frame(height: pictureHeight)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(item.title).font(.caption2).lineLimit(2, reservesSpace: true)
            Text(item.price ?? " ").font(.caption.weight(.bold)).monospacedDigit()
        }
        .padding(6)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint, lineWidth: lit ? 2 : 0))
        .scaleEffect(chosen ? 1.06 : lit ? 1.02 : 1)
        .shadow(color: .black.opacity(lit ? 0.15 : 0), radius: 6, y: 3)
    }
}

/// A picture from the site, fitted, with a shimmer while it comes.
private struct StagePicture: View {
    let url: String?
    var padding: CGFloat = 4

    var body: some View {
        if let link = url.flatMap(URL.init(string:)) {
            AsyncImage(url: link) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fit).padding(padding)
                case .failure: Image(systemName: "photo").foregroundStyle(.tertiary)
                default: Rectangle().fill(Theme.chip).shimmering()
                }
            }
        } else {
            Image(systemName: "photo").foregroundStyle(.tertiary)
        }
    }
}

/// Aide's finger: where it's looking, and a press when it taps.
private struct Cursor: View {
    let tint: Color
    let pressing: Bool

    var body: some View {
        ZStack {
            if pressing { TapMark(tint: tint) }
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white, tint)
                .symbolRenderingMode(.palette)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .scaleEffect(pressing ? 0.85 : 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ProductStage: View {
    let scene: PageScene
    let action: BrowserLive.Action?
    let tint: Color
    @State private var flight: Int?
    @State private var flown: CGFloat = 0

    private var reading: Bool { ["read", "find", "look", "scroll", "open"].contains(action?.kind ?? "read") }

    var body: some View {
        let product = scene.product
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    StagePicture(url: product?.image, padding: 12)
                    if reading { ScanLine(tint: tint) }
                }
                .frame(maxWidth: .infinity)
                .frame(height: geo.size.height * 0.55)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(product?.title ?? scene.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                HStack(alignment: .firstTextBaseline) {
                    if let price = product?.price {
                        Text(price).font(.title3.weight(.bold)).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    if let rating = product?.rating { Stars(rating: rating) }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .overlay {
                // Into the cart: the picture flies up to the bar.
                if flight != nil {
                    StagePicture(url: product?.image)
                        .frame(width: 76, height: 76)
                        .background(Color.white, in: Circle())
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                        .modifier(Fly(progress: flown, to: CGSize(width: geo.size.width / 2 - 30, height: -geo.size.height / 2 - 16)))
                }
            }
        }
        .onChange(of: action) { _, action in
            guard let action, action.addsToCart else { return }
            flown = 0
            flight = action.seq
            withAnimation(.easeIn(duration: 0.8)) { flown = 1 } completion: { flight = nil }
        }
    }
}

/// Along an arc to `to`, getting smaller.
private struct Fly: ViewModifier, Animatable {
    var progress: CGFloat
    let to: CGSize

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - 0.75 * progress)
            .offset(x: to.width * progress, y: to.height * progress - sin(progress * .pi) * 50)
            .opacity(1 - 0.7 * progress)
    }
}

/// A line sweeping down a picture: Aide is reading it.
private struct ScanLine: View {
    let tint: Color
    @State private var down = false

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [tint.opacity(0), tint.opacity(0.35), tint.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 44)
                .offset(y: down ? geo.size.height - 22 : -22)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { down = true }
        }
    }
}

private struct Stars: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { i in
                let left = rating - Double(i)
                Image(systemName: left >= 0.75 ? "star.fill" : left >= 0.25 ? "star.leadinghalf.filled" : "star")
            }
            Text(rating.formatted(.number.precision(.fractionLength(1)))).padding(.leading, 3).foregroundStyle(.secondary)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .accessibilityElement()
        .accessibilityLabel("\(rating.formatted()) out of 5")
    }
}

private struct CartStage: View {
    let scene: PageScene
    let confirming: Bool
    let tint: Color

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: scene.kind == "checkout" ? "creditcard.fill" : "cart.fill")
                .font(.system(size: 42))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: scene.cart?.total)
            Text(scene.kind == "checkout" ? "Checkout" : "Cart").font(.headline)
            if let total = scene.cart?.total {
                Text(total).font(.largeTitle.weight(.bold)).monospacedDigit().contentTransition(.numericText())
            }
            if let count = scene.cart?.count, count > 0 {
                Text(count == 1 ? "1 item" : "\(count) items").font(.subheadline).foregroundStyle(.secondary)
            }
            if confirming {
                Label("Waiting for your Confirm", systemImage: "checkmark.shield.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.orange.opacity(0.15), in: Capsule())
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(12)
    }
}

/// A check that draws itself.
struct DoneStage: View {
    let text: String
    let tint: Color
    @State private var drawn: CGFloat = 0

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle().fill(tint.opacity(0.15)).frame(width: 92, height: 92)
                Check().trim(from: 0, to: drawn)
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    .frame(width: 40, height: 34)
            }
            Text(text).font(.headline)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { withAnimation(.easeOut(duration: 0.6).delay(0.2)) { drawn = 1 } }
    }

    private struct Check: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            return path
        }
    }
}

private struct TurnStage: View {
    let scene: PageScene
    let tint: Color
    let open: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack(alignment: .bottomTrailing) {
                SiteIcon(url: scene.iconURL, size: 56)
                Image(systemName: scene.turnSymbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(6)
                    .background(tint, in: Circle())
                    .offset(x: 8, y: 8)
            }
            Text(scene.turnTitle).font(.headline).multilineTextAlignment(.center)
            Text(open == nil ? "Aide is getting there." : "Your turn: Aide waits while you do this part.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let open {
                Button(scene.turnButton, action: open)
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.onAccent)
                    .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }
}

/// Any other page: its title, the page as lines, a scroll when Aide scrolls, a ring where it taps.
private struct PageStage: View {
    let scene: PageScene
    let action: BrowserLive.Action?
    let tint: Color
    @State private var shift: CGFloat = 0

    private static let widths: [CGFloat] = [1, 0.92, 0.97, 0.6, 0.85, 1, 0.7, 0.9, 0.5, 0.95, 0.8, 0.65]

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 10) {
                Text(scene.title ?? scene.siteName).font(.headline).lineLimit(2)
                ForEach(Array(Self.widths.enumerated()), id: \.offset) { _, width in
                    RoundedRectangle(cornerRadius: 4).fill(Theme.chip)
                        .frame(width: (geo.size.width - 24) * width, height: 10)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .offset(y: shift)
            .overlay {
                if ["read", "look", "find"].contains(action?.kind ?? "") { ScanLine(tint: tint) }
            }
            .overlay {
                if let action, action.kind == "click", let point = action.point {
                    TapMark(tint: tint)
                        .id(action.seq)
                        .position(x: point.x * geo.size.width, y: point.y * geo.size.height)
                }
            }
        }
        .onChange(of: action) { _, action in
            guard let action, action.kind == "scroll" else { return }
            let by: CGFloat = action.label == "up" ? 40 : -40
            withAnimation(.easeOut(duration: 0.35)) { shift = by }
            withAnimation(.spring(duration: 0.5).delay(0.35)) { shift = 0 }
        }
    }
}

private struct SkeletonStage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 10).fill(Theme.chip).frame(height: 30)
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 12).fill(Theme.chip)
                RoundedRectangle(cornerRadius: 12).fill(Theme.chip)
            }
            .frame(height: 118)
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4).fill(Theme.chip).frame(height: 10)
                    .padding(.trailing, CGFloat(i % 2) * 60)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .shimmering()
    }
}

// MARK: - The sheet

/// The errand full size, and the app's own screen for your part: a login (AutoFill offers your password and the
/// SMS code), a choice of where to send the code, a CAPTCHA's picture. What you enter goes straight into the page;
/// Aide never sees it. When the page moves on from the login, it says so and Aide goes on by itself.
struct StageSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let target: BrowserTarget
    var tint: Color = Theme.glow
    /// After it closes, to load the errand again.
    var onClose: () -> Void = {}

    @StateObject private var live = BrowserLive()
    @State private var values: [String: String] = [:]
    @State private var chosen: String?
    /// A form went: waiting for the page to answer.
    @State private var sending = false
    /// You sent something on a login, a code or a CAPTCHA (so leaving them means it worked).
    @State private var tried = false
    @State private var loggedIn = false
    @State private var realPage = false
    @State private var finishing = false
    @FocusState private var focused: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                    if !loggedIn {
                        // Out of the way: for what Aide's own screens don't cover.
                        Button { realPage = true } label: {
                            Text("Open the real page").font(.footnote).underline().foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                    }
                }
                .padding(16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) { footer }
            .background(Theme.grouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { close() } }
            }
        }
        .task { connect() }
        .onDisappear { live.disconnect() }
        .onChange(of: live.scene) { old, new in moved(from: old, to: new) }
        .fullScreenCover(isPresented: $realPage) {
            BrowserSheet(target: target) {
                if case .site = target { close() }
            }
        }
    }

    private var title: String {
        switch target {
        case .errand(_, let title): title
        case .site(let site): site
        }
    }

    private var isSite: Bool { if case .site = target { true } else { false } }

    @ViewBuilder
    private var content: some View {
        if loggedIn {
            DoneStage(text: "Logged in to \(live.scene?.siteName ?? title)", tint: tint).frame(height: 300)
            Text(isSite ? "Aide's browser stays logged in there." : "Aide goes on from here.")
                .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        } else if let closed = live.closed {
            Label(closed, systemImage: "wifi.exclamationmark")
            Button("Try again") { connect() }.buttonStyle(.bordered)
        } else if live.control, let scene = live.scene, scene.isYourTurn {
            yourTurn(scene)
        } else {
            if live.control, let reason = live.status?.reason {
                Label(reason, systemImage: "hand.point.up.left.fill").font(.subheadline)
            }
            ErrandStage(scene: live.scene, action: live.action, tint: tint,
                        confirming: live.status?.status == "waiting_confirm", large: true)
                .frame(height: 520)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line))
            if !live.control {
                Narration(text: live.action?.said ?? live.status?.step ?? "Opening the page…", tint: tint)
            } else if let signin = live.scene?.signin {
                Button {
                    live.press(ref: signin)
                } label: {
                    Label("Go to the login", systemImage: "person.crop.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private func yourTurn(_ scene: PageScene) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SiteIcon(url: scene.iconURL, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.turnTitle).font(.title3.weight(.semibold))
                    Text("Aide types it into \(scene.siteName) for you, and never sees it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let error = scene.form?.error {
                Label(error, systemImage: "exclamationmark.circle.fill").font(.subheadline).foregroundStyle(.red)
            }
            if scene.kind == "captcha", let captcha = scene.captcha {
                captchaView(captcha)
            } else if let form = scene.form, !form.fields.isEmpty || form.submit != nil || !form.choices.isEmpty {
                formView(form)
            } else {
                Text("This one needs the real page.").font(.subheadline)
                Button("Open the real page") { realPage = true }.buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.onAccent)
            }
        }
        .padding(16)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.spring(duration: 0.35), value: scene)
    }

    @ViewBuilder
    private func formView(_ form: PageScene.Fields) -> some View {
        ForEach(form.fields) { field in
            PageField(kind: field.kind, label: field.label ?? (field.filled ? "Filled in" : nil), text: binding(field.ref))
                .focused($focused, equals: field.ref)
                .submitLabel(field.id == form.fields.last?.id ? .go : .next)
                .onSubmit { next(after: field, in: form) }
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        if !form.choices.isEmpty {
            VStack(spacing: 0) {
                ForEach(form.choices) { choice in
                    Button {
                        chosen = choice.ref
                        live.press(ref: choice.ref)
                    } label: {
                        HStack {
                            Text(choice.text ?? "Option").multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: chosen == choice.ref ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(chosen == choice.ref ? tint : .secondary)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if choice.id != form.choices.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 12)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        Button { submit(form) } label: {
            HStack(spacing: 8) {
                if sending { ProgressView() }
                Text(form.submit?.text ?? "Continue")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .foregroundStyle(Theme.onAccent)
        .controlSize(.large)
        .disabled(sending || !Self.ready(form, values))
    }

    @ViewBuilder
    private func captchaView(_ captcha: PageScene.Captcha) -> some View {
        if let crop = live.crop {
            Image(uiImage: crop.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    GeometryReader { geo in
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { p in
                                guard captcha.kind != "text", geo.size.width > 0, geo.size.height > 0 else { return }
                                let point = crop.pagePoint(u: p.x / geo.size.width, v: p.y / geo.size.height)
                                live.tap(x: point.x, y: point.y)
                                tried = true
                            }
                    }
                }
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 80)
        }
        if captcha.kind == "text", let input = captcha.inputRef {
            PageField(kind: "text", label: "The characters in the picture", text: binding(input))
                .focused($focused, equals: input)
                .submitLabel(.go)
                .onSubmit { solve(captcha) }
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button { solve(captcha) } label: {
                HStack(spacing: 8) {
                    if sending { ProgressView() }
                    Text("Continue")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Theme.onAccent)
            .controlSize(.large)
            .disabled(sending || (values[input] ?? "").isEmpty)
        } else {
            Text("Tap the picture as it asks: your taps go to the page.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if live.control && !loggedIn && !(live.scene?.isYourTurn ?? false) {
            Button {
                Task { await finish() }
            } label: {
                Group { if finishing { ProgressView() } else { Text(isSite ? "Done" : "I'm done") } }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Theme.onAccent)
            .controlSize(.large)
            .disabled(finishing)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Theme.grouped)
        }
    }

    /// Every field has something, or the page already had it.
    static func ready(_ form: PageScene.Fields, _ values: [String: String]) -> Bool {
        form.fields.allSatisfy { $0.filled || !(values[$0.ref] ?? "").isEmpty }
    }

    private func binding(_ ref: String) -> Binding<String> {
        Binding(get: { values[ref] ?? "" }, set: { values[ref] = $0 })
    }

    private func next(after field: PageScene.Field, in form: PageScene.Fields) {
        if let i = form.fields.firstIndex(of: field), i + 1 < form.fields.count {
            focused = form.fields[i + 1].ref
        } else if Self.ready(form, values) {
            submit(form)
        }
    }

    /// The fields into the page, then its button (or Enter).
    private func submit(_ form: PageScene.Fields) {
        for field in form.fields {
            if let value = values[field.ref], !value.isEmpty { live.fill(ref: field.ref, text: value) }
        }
        if let submit = form.submit { live.press(ref: submit.ref) } else { live.key("Enter") }
        sent()
    }

    private func solve(_ captcha: PageScene.Captcha) {
        guard let input = captcha.inputRef, let value = values[input], !value.isEmpty else { return }
        live.fill(ref: input, text: value)
        if let submit = captcha.submitRef { live.press(ref: submit) } else { live.key("Enter") }
        sent()
    }

    private func sent() {
        focused = nil
        sending = true
        tried = true
        Task {
            try? await Task.sleep(for: .seconds(8))
            sending = false // the page didn't move: let them try again
        }
    }

    /// A new page clears what you typed; leaving the login after you sent it means you're in.
    private func moved(from old: PageScene?, to new: PageScene?) {
        guard let new else { return }
        if old?.kind != new.kind || old?.url != new.url || old?.form?.fields.map(\.ref) != new.form?.fields.map(\.ref) {
            values = [:]
            chosen = nil
            sending = false
        } else if new.form?.error != old?.form?.error {
            sending = false
        }
        if tried && !new.isYourTurn && live.control && !loggedIn {
            withAnimation(.spring(duration: 0.4)) { loggedIn = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                await finish()
            }
        }
    }

    private func connect() {
        let request: URLRequest?
        switch target {
        case .errand(let id, _): request = try? env.api.browserLiveRequest(errand: id, frames: false)
        case .site(let site): request = try? env.api.browserLiveRequest(site: site, frames: false)
        }
        if let request { live.connect(request) }
    }

    private func finish() async {
        guard !finishing else { return }
        finishing = true
        await live.done()
        finishing = false
        onClose()
        dismiss()
    }

    private func close() {
        live.disconnect()
        onClose()
        dismiss()
    }
}

/// Aide's line for what it's doing, under the stage.
struct Narration: View {
    let text: String
    let tint: Color

    var body: some View {
        Label {
            Text(text).lineLimit(2).id(text).transition(.push(from: .bottom).combined(with: .opacity))
        } icon: {
            Image(systemName: "sparkle").foregroundStyle(tint).symbolEffect(.pulse)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .animation(.spring(duration: 0.4), value: text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

/// A native field for one of the page's: a password one is secure and a code one takes the SMS code, so the
/// phone's AutoFill offers them.
struct PageField: View {
    let kind: String
    let label: String?
    @Binding var text: String

    var body: some View {
        Group {
            switch kind {
            case "password":
                SecureField(label ?? "Password", text: $text)
                    .textContentType(.password)
            case "username":
                TextField(label ?? "Email or username", text: $text)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
            case "code":
                TextField(label ?? "Code", text: $text)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
            case "phone":
                TextField(label ?? "Phone", text: $text)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
            case "number":
                TextField(label ?? "Number", text: $text)
                    .keyboardType(.decimalPad)
            default:
                TextField(label ?? "Type here", text: $text)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }
}
