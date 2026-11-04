import SwiftUI

// Release trackers (docs/API.md, "Browser errands", Release trackers): the research's colourways in a card, a picker
// drawn like a shop's page in a browser (colourways, size, the most you'd pay, shops, tell me or buy it), and what's set
// up for each pick.

/// A release in chat: its colourways in a strip, where it stands, and the picker or the plan.
struct ReleaseCard: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var release: Release
    @State private var showsPicker = false
    @State private var note: String?
    /// In a chat the card is the release as it was: load it fresh once.
    private let refreshes: Bool
    var deleted: (() -> Void)?

    init(release: Release, refreshes: Bool = true, deleted: (() -> Void)? = nil) {
        _release = State(initialValue: release)
        self.refreshes = refreshes
        self.deleted = deleted
    }

    var body: some View {
        Button { showsPicker = true } label: { content }
            .buttonStyle(CardPress())
            .disabled(release.status == "researching")
            .sheet(isPresented: $showsPicker) {
                ReleaseSheet(release: release) { release = $0 } deleted: { note = "Deleted."; deleted?() }
            }
            .task(id: release.id) { if refreshes { await refresh() } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 42, height: 42)
                    .background(release.status == "failed" ? Color.red.opacity(0.8) : Theme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(release.title).font(.headline).lineLimit(2)
                    Text(release.state).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                if release.status == "researching" { ProgressView() }
            }
            .multilineTextAlignment(.leading)
            if !release.colourways.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(release.colourways) { c in
                            VStack(alignment: .leading, spacing: 3) {
                                ColourwayThumb(colourway: c, selected: c.picked, size: Self.thumb)
                                Text(Self.caption(c.name))
                                    .font(.caption.weight(.semibold)).lineLimit(1)
                                Text(c.when).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: Self.thumb, alignment: .leading)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            if release.status == "tracking" {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(release.picked) { c in
                        Label(c.plan?.text ?? "\(c.name): waiting for a date and time", systemImage: planIcon(c.plan))
                            .lineLimit(2)
                    }
                }
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            }
            if release.status == "ready" || release.status == "tracking" {
                Text(release.status == "ready" ? "Pick what you want" : "See and change")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(Theme.accent, in: Capsule())
            }
            if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// "Sea Glass/Laser Crimson/Phantom (Men's)" → "Sea Glass · Men's": the first colour, and who it's for.
    static func caption(_ name: String) -> String {
        let first = name.components(separatedBy: "/").first?.trimmingCharacters(in: .whitespaces) ?? name
        guard let open = name.lastIndex(of: "("), name.hasSuffix(")") else { return first }
        let who = name[name.index(after: open)..<name.index(before: name.endIndex)]
        return first.contains("(") ? first : "\(first) · \(who)"
    }

    #if os(macOS)
    private static let thumb: CGFloat = 132
    #else
    private static let thumb: CGFloat = 108
    #endif

    private var icon: String {
        switch release.status {
        case "researching": "magnifyingglass"
        case "failed": "exclamationmark.triangle.fill"
        case "stopped": "pause.fill"
        case "tracking": "calendar.badge.clock"
        default: "shoeprints.fill"
        }
    }

    private func refresh() async {
        if let fresh = try? await env.api.release(release.id) { release = fresh }
    }
}

func planIcon(_ plan: ReleasePlan?) -> String {
    switch plan?.what {
    case "drop": "timer"
    case "reminder": "bell.fill"
    case "watch": "eye.fill"
    case "errand": "cart.fill"
    case "told": "checkmark"
    default: "hourglass"
    }
}

/// A colourway's picture, small, ringed when picked.
struct ColourwayThumb: View {
    let colourway: ReleaseColourway
    var selected = false
    var size: CGFloat = 64

    var body: some View {
        ColourwayPicture(colourway: colourway, padding: 4)
            .frame(width: size, height: size)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 2.5 : 0.5)
            }
            .overlay(alignment: .topTrailing) {
                if colourway.new == true {
                    Text("NEW").font(.system(size: 8, weight: .heavy)).padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color.orange, in: Capsule()).foregroundStyle(.white).padding(3)
                }
            }
            .accessibilityLabel(colourway.name + (selected ? ", picked" : ""))
    }
}

struct ColourwayPicture: View {
    let colourway: ReleaseColourway
    var padding: CGFloat = 12

    var body: some View {
        AsyncImage(url: colourway.imageURL) { phase in
            switch phase {
            case .success(let image): image.resizable().aspectRatio(contentMode: .fit).padding(padding)
            case .failure: placeholder
            default: if colourway.image == nil { placeholder } else { ProgressView() }
            }
        }
    }

    private var placeholder: some View {
        Image(systemName: "shoeprints.fill").font(.title2).foregroundStyle(.gray.opacity(0.5))
    }
}

// MARK: - The picker

/// The release drawn as a shop's page in a browser: pick colourways, a size, the most you'd pay, the shops, and
/// whether Aide tells you or buys at the drop. Once tracking, the plan for each pick, the log, Check now and Stop.
struct ReleaseSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var release: Release
    @State private var chosen: Set<String>
    @State private var size: String?
    @State private var maxText: String
    @State private var shops: Set<String>
    @State private var buy: Bool
    @State private var page: String?
    @State private var busy = false
    @State private var error: String?
    let changed: (Release) -> Void
    let deleted: () -> Void

    static let sizes = ["38.5", "39", "40", "40.5", "41", "42", "42.5", "43", "44", "44.5", "45", "45.5", "46", "47",
                        "47.5", "48.5"]

    init(release: Release, changed: @escaping (Release) -> Void, deleted: @escaping () -> Void) {
        _release = State(initialValue: release)
        let picks = release.picks
        _chosen = State(initialValue: Set(release.picked.map(\.key)))
        _size = State(initialValue: picks?.size.map { $0.replacingOccurrences(of: "EU", with: "").trimmingCharacters(in: .whitespaces) })
        _maxText = State(initialValue: picks?.maxTotal.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "")
        _shops = State(initialValue: Set(picks?.shops ?? []))
        _buy = State(initialValue: picks?.mode == "buy")
        _page = State(initialValue: release.colourways.first?.key)
        self.changed = changed
        self.deleted = deleted
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ReleaseBar(title: release.title, busy: busy) { dismiss() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        carousel
                        if let summary = release.summary, !summary.isEmpty {
                            Text(summary).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if release.status == "tracking" || release.status == "stopped" { plan }
                        sizes
                        if !release.shops.isEmpty { shopChips }
                        mode
                        if !release.log.isEmpty { log }
                        if !release.sources.isEmpty { sources }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                        }
                    }
                    .padding(16)
                    .pageColumn()
                }
                .background(Theme.background)
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .toolbar(.hidden, for: .navigationBar)
            .macSheetHidesClose()
        }
    }

    // A page per colourway, as a shop shows its product, with Want this: swipe, the arrows or a thumbnail to move.
    private var carousel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let c = current {
                ColourwayPage(colourway: c, chosen: chosen.contains(c.key)) { toggle(c.key) }
                    .id(c.key)
                    .transition(.opacity)
                    .overlay(alignment: .top) {
                        if release.colourways.count > 1 {
                            HStack {
                                arrow("chevron.left", by: -1)
                                Spacer()
                                arrow("chevron.right", by: 1)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 220)
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 24).onEnded { v in
                        guard abs(v.translation.width) > abs(v.translation.height) else { return }
                        move(v.translation.width < 0 ? 1 : -1)
                    })
            }
            HStack(spacing: 8) {
                ForEach(release.colourways) { c in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { page = c.key } } label: {
                        ColourwayThumb(colourway: c, selected: chosen.contains(c.key), size: 48)
                            .opacity(page == c.key ? 1 : 0.55)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var current: ReleaseColourway? {
        release.colourways.first { $0.key == page } ?? release.colourways.first
    }

    private func move(_ by: Int) {
        let keys = release.colourways.map(\.key)
        guard let i = keys.firstIndex(of: current?.key ?? "") else { return }
        let j = i + by
        guard keys.indices.contains(j) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { page = keys[j] }
    }

    private func arrow(_ symbol: String, by: Int) -> some View {
        let keys = release.colourways.map(\.key)
        let i = keys.firstIndex(of: current?.key ?? "") ?? 0
        let can = keys.indices.contains(i + by)
        return Button { move(by) } label: {
            Image(systemName: symbol).font(.footnote.weight(.bold))
                .frame(width: 30, height: 30)
                .foregroundStyle(.black.opacity(0.7))
                .background(.white.opacity(0.85), in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .opacity(can ? 1 : 0)
        .disabled(!can)
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("What's set up")
            ForEach(release.picked) { c in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: planIcon(c.plan)).frame(width: 22).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.subheadline.weight(.semibold))
                        Text(c.plan?.text ?? "Waiting for a date and time: Aide looks every day.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if release.status == "stopped" {
                Text("Stopped: nothing is set up and nobody looks.").font(.footnote).foregroundStyle(.secondary)
            } else if let next = release.nextAt.flatMap(Wire.parse) {
                Text("Next look \(next.formatted(.relative(presentation: .named))).").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var sizes: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                heading("Size")
                Spacer()
                Text("EU").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 8)], spacing: 8) {
                ForEach(Self.sizes, id: \.self) { s in
                    Button { size = size == s ? nil : s } label: {
                        Text(s).font(.subheadline.weight(.medium)).monospacedDigit()
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .foregroundStyle(size == s ? Theme.onAccent : .primary)
                            .background(size == s ? Theme.accent : Theme.chip,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var shopChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Shops")
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(release.shops, id: \.self) { s in
                        Chip(title: s, systemImage: shops.contains(s) ? "checkmark" : nil,
                             style: shops.contains(s) ? .prominent : .plain) {
                            if shops.contains(s) { shops.remove(s) } else { shops.insert(s) }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            Text(shops.isEmpty ? "None picked: any shop that sells it in Italy." : "In this order of the list: the first one that sells it.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var mode: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("When it drops")
            Picker("When it drops", selection: $buy) {
                Text("Tell me").tag(false)
                Text("Buy it for me").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if buy {
                HStack {
                    Text("The most you'd pay").font(.subheadline)
                    Spacer()
                    TextField("320", text: $maxText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 90)
                    Text("€").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).frame(height: 44)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("Delivery included. Aide gets ready on the shop's page ahead, asks you to Confirm these limits once, opens it 5 minutes before and buys only that colourway in your size at or under this. Logins are yours, in the live view. A draw is never entered for you: you get a reminder.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("A reminder 10 minutes before each drop, and a note when a date, time or price changes. Sold out: a watch tells you if it's back.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var log: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("What changed")
            ForEach(Array(release.log.prefix(8).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Wire.parse(line.ts)?.formatted(.dateTime.day().month(.abbreviated)) ?? "")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                    Text(line.text).font(.footnote)
                }
            }
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading("Sources")
            ForEach(release.sources, id: \.url) { s in
                if let url = URL(string: s.url) {
                    Link(destination: url) { Label(s.title, systemImage: "link").font(.footnote).lineLimit(1) }
                }
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.headline)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if release.status == "tracking" {
                    Button { Task { await run { try await env.api.checkRelease(release.id) } } } label: {
                        Text("Check now").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) { Task { await run { try await env.api.stopRelease(release.id) } } } label: {
                        Text("Stop").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else if release.status == "stopped" {
                    Button { Task { await run { try await env.api.resumeRelease(release.id) } } } label: {
                        Text("Track again").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) { Task { await delete() } } label: {
                        Text("Delete").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            Button { Task { await save() } } label: {
                HStack {
                    Text(saveTitle)
                    if busy { ProgressView().tint(Theme.onAccent) }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Theme.onAccent)
            .disabled(!canSave)
        }
        .controlSize(.large)
        .disabled(busy)
        .padding(16)
        .background(.bar)
    }

    private var saveTitle: String {
        let n = chosen.count
        if n == 0 { return "Pick a colourway" }
        if buy && size == nil { return "Pick a size" }
        if buy && maxValue == nil { return "Set the most you'd pay" }
        let what = "\(n) colourway\(n == 1 ? "" : "s")"
        return release.status == "tracking" ? "Save · \(what)" : "Start tracking · \(what)"
    }

    private var maxValue: Double? {
        Double(maxText.replacingOccurrences(of: "€", with: "").replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }

    private var canSave: Bool { !chosen.isEmpty && (!buy || (size != nil && maxValue != nil)) }

    private func toggle(_ key: String) {
        if chosen.contains(key) { chosen.remove(key) } else { chosen.insert(key) }
    }

    private func save() async {
        let ordered = release.shops.filter(shops.contains)
        let picks = ReleasePicks(colourways: release.colourways.map(\.key).filter(chosen.contains),
                                 size: size.map { "EU \($0)" }, maxTotal: buy ? maxValue : nil, currency: "EUR",
                                 shops: ordered, mode: buy ? "buy" : "tell")
        await run { try await env.api.setReleasePicks(release.id, picks) }
        if error == nil { dismiss() }
    }

    private func run(_ call: () async throws -> Release) async {
        busy = true
        defer { busy = false }
        do {
            release = try await call()
            changed(release)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func delete() async {
        do { try await env.api.deleteRelease(release.id); deleted(); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

/// The bar of a browser window, drawn: the lights (the red one closes), the address with its lock.
struct ReleaseBar: View {
    let title: String
    let busy: Bool
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Button(action: close) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                        .overlay { Image(systemName: "xmark").font(.system(size: 6.5, weight: .black)).foregroundStyle(.black.opacity(0.55)) }
                        .frame(width: 12, height: 12)
                        .padding(8).contentShape(Rectangle()).padding(-8)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12, height: 12)
            }
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                Text("releases · \(title.lowercased())").lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).frame(height: 24)
            .frame(maxWidth: 260)
            .background(Theme.background.opacity(0.6), in: Capsule())
            .frame(maxWidth: .infinity)
            Group { if busy { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise").foregroundStyle(.secondary) } }
                .font(.caption.weight(.semibold))
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.chip.opacity(0.75))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }
}

/// One colourway as a shop's product page: the picture, name and code, the price, when it drops and how, Want this.
struct ColourwayPage: View {
    @Environment(\.openURL) private var openURL
    let colourway: ReleaseColourway
    let chosen: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ColourwayPicture(colourway: colourway, padding: 18)
                .frame(maxWidth: .infinity).frame(height: 220)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        pill(status, colour: statusColour)
                        if colourway.isDraw { pill("Draw", colour: .purple) }
                        if colourway.new == true { pill("New", colour: .orange) }
                    }
                    .padding(10)
                }
                .onTapGesture { if let url = colourway.url.flatMap(URL.init(string:)) { openURL(url) } }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(colourway.name).font(.title3.weight(.semibold)).lineLimit(2)
                    if let code = colourway.code { Text(code).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                if let price = colourway.price { Text(price).font(.title3.weight(.bold)).monospacedDigit() }
            }
            Label(colourway.when, systemImage: "calendar").font(.subheadline.weight(.medium))
            if let note = colourway.note, !note.isEmpty {
                Text(note).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
            if let shops = colourway.shops, !shops.isEmpty {
                Text(shops.map(\.site).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button(action: toggle) {
                Label(chosen ? "Picked" : "Want this", systemImage: chosen ? "checkmark.circle.fill" : "plus.circle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .foregroundStyle(chosen ? Theme.onAccent : .primary)
                    .background(chosen ? Theme.accent : Theme.chip, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var status: String {
        switch colourway.status {
        case "out": "Available"
        case "sold_out": "Sold out"
        case "upcoming": "Coming"
        default: "Rumoured"
        }
    }

    private var statusColour: Color {
        switch colourway.status {
        case "out": .green
        case "sold_out": .gray
        case "upcoming": .blue
        default: .secondary
        }
    }

    private func pill(_ text: String, colour: Color) -> some View {
        Text(text).font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(colour.opacity(0.9), in: Capsule())
    }
}

// MARK: - The list

/// Settings → Browser → Releases: every release followed.
struct ReleasesView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var list: ReleaseList?
    @State private var error: String?

    var body: some View {
        List {
            if let list {
                if !list.enabled {
                    Text("The server has no browser yet, so it can't follow releases.").foregroundStyle(.secondary)
                } else if list.releases.isEmpty {
                    Text("None yet. Ask Aide: \u{201C}follow the Nike Alphafly 4 release\u{201D}.").foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(list.releases) { r in
                            ReleaseCard(release: r, refreshes: false, deleted: { Task { await load() } })
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    } footer: {
                        Text("Aide looks each day (every 6 hours in the last 4 days), and sets up a timed drop or a reminder once a picked colourway has its date and time.")
                    }
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Releases")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do { list = try await env.api.releases(); error = nil } catch { self.error = error.localizedDescription }
    }
}
