import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// YouTube videos Aide reads (docs/API.md, "Videos"): the card in chat, the page with the brief, the brief as slides,
// and the list in Settings.

// MARK: - In chat

/// A video's card under Aide's message: the thumbnail, then what it's doing, or the gist once it's read. It follows
/// the video while it's being read; a tap on a read one opens its page.
struct VideoCardView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var chat: ChatViewModel
    @State private var video: VideoCard
    @State private var page: VideoCard?

    init(card: VideoCard) { _video = State(initialValue: card) }

    var body: some View {
        Button { if video.isReady { page = video } } label: {
            VStack(alignment: .leading, spacing: 0) {
                VideoThumbnail(video: video)
                VStack(alignment: .leading, spacing: 6) {
                    Text(video.title ?? "A YouTube video").font(.headline).lineLimit(2)
                        .redacted(reason: video.title == nil ? .placeholder : [])
                    if let byline = VideoThumbnail.byline(video) {
                        Text(byline).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    status
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: video.id) { await follow() }
        .sheet(item: $page) { v in VideoPage(id: v.id).macCoverSize() }
        .contextMenu {
            if let url = URL(string: video.url) {
                Link(destination: url) { Label("Open in YouTube", systemImage: "play.rectangle") }
                ShareLink(item: url) { Label("Share the video", systemImage: "square.and.arrow.up") }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if video.isWorking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(video.step ?? "Waiting to start").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        } else if video.isFailed {
            Label(video.error ?? "I couldn't read it.", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline).foregroundStyle(.orange)
        } else {
            if let gist = video.gist {
                Text(gist).font(.subheadline).foregroundStyle(.primary.opacity(0.85)).lineLimit(4)
            }
            HStack(spacing: 6) {
                Image(systemName: "sparkles.rectangle.stack")
                Text(VideoThumbnail.counts(video))
                Spacer(minLength: 0)
                Text("Open").fontWeight(.semibold)
                Image(systemName: "chevron.right").font(.caption.weight(.bold))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
    }

    /// Every few seconds while it's being read; when it's done, the chat loads the message with the brief.
    private func follow() async {
        while !Task.isCancelled && video.isWorking {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let fresh = try? await env.api.video(video.id) else { continue }
            let done = fresh.status != video.status && fresh.status != "working"
            withAnimation(.snappy) { video = VideoCard(fresh) }
            if done, let id = fresh.conversationId, id == chat.conversationID { await chat.loadHistory() }
        }
    }
}

extension VideoCard {
    /// The card part of a full Video.
    init(_ v: Video) {
        self.init(id: v.id, youtubeId: v.youtubeId, url: v.url, status: v.status, step: v.step, error: v.error,
                  title: v.title, channel: v.channel, duration: v.duration, thumbnail: v.thumbnail, gist: v.gist,
                  moments: v.moments?.count, frames: v.moments?.filter { $0.frame != nil }.count, cover: v.cover,
                  createdAt: v.createdAt)
    }
}

/// YouTube's thumbnail, 16:9, with the length in the corner; dimmed while the video is being read.
struct VideoThumbnail: View {
    let video: VideoCard
    var corner: CGFloat = 0

    var body: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                AsyncImage(url: video.thumbnailURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Theme.card
                }
            }
            .overlay {
                if video.isWorking {
                    Color.black.opacity(0.35)
                } else if video.isReady {
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.black.opacity(0.45), in: Circle())
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let d = video.duration {
                    Text(VideoCard.clock(d))
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .accessibilityHidden(true)
    }

    static func byline(_ v: VideoCard) -> String? {
        let parts = [v.channel, v.duration.map { VideoCard.clock($0) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func counts(_ v: VideoCard) -> String {
        let moments = v.moments ?? 0
        var text = "\(moments) key moment\(moments == 1 ? "" : "s")"
        if let frames = v.frames, frames > 0 { text += " · \(frames) frame\(frames == 1 ? "" : "s")" }
        return text
    }
}

// MARK: - The page

/// A video's brief: what it's about, what to know, the key moments with their times (each opens YouTube there) and
/// frames, and the brief as slides.
struct VideoPage: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let id: String
    /// From Settings: a button to its chat.
    var showsChat = false
    @State private var video: Video?
    @State private var error: String?
    @State private var slides = false
    @State private var zoomed: ZoomTarget?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let video {
                    content(video)
                } else if let error {
                    ContentUnavailableView("Couldn't load the video", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                        .padding(.top, 80)
                } else {
                    loading
                }
            }
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                #endif
                if let video, let url = video.watchURL {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
            .task(id: id) {
                await load()
                #if DEBUG
                if env.settings.isPreview, UserDefaults.standard.string(forKey: "previewVideo") == "slides" { slides = true }
                #endif
            }
            .fullScreenCover(isPresented: $slides) {
                if let video { VideoSlides(video: video) }
            }
            .fullScreenCover(item: $zoomed) { target in
                ZoomedImage(image: target.image, caption: target.caption)
            }
        }
    }

    private func content(_ v: Video) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 14) {
                Button { if let url = v.watchURL { openURL(url) } } label: {
                    VideoThumbnail(video: VideoCard(v), corner: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open in YouTube")
                VStack(alignment: .leading, spacing: 6) {
                    Text(v.title ?? "A YouTube video").font(.title2.weight(.bold))
                    Text(Self.byline(v)).font(.subheadline).foregroundStyle(.secondary)
                }
                if v.status == "ready" {
                    HStack(spacing: 10) {
                        Button { slides = true } label: {
                            Label("Play as slides", systemImage: "play.square.stack.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .foregroundStyle(Theme.onAccent)
                        if let url = v.watchURL {
                            Link(destination: url) {
                                Label("YouTube", systemImage: "play.rectangle.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    }
                    .controlSize(.large)
                    .fontWeight(.semibold)
                }
            }
            if v.status != "ready" {
                notReady(v)
            } else {
                if let question = v.question {
                    callout("You asked", question, answer: v.answer, symbol: "questionmark.bubble.fill")
                }
                if let tldr = v.tldr {
                    section("TL;DR") { Text(tldr).font(.body).fixedSize(horizontal: false, vertical: true) }
                }
                if !v.points.isEmpty {
                    section("What you should know") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(v.points.enumerated()), id: \.offset) { _, point in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(y: -2)
                                    Text(point).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                if !v.keyMoments.isEmpty {
                    section("Key moments") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(v.keyMoments.enumerated()), id: \.element.id) { i, m in
                                MomentRow(moment: m, last: i == v.keyMoments.count - 1) { image in
                                    zoomed = ZoomTarget(image: image, caption: m.title)
                                }
                            }
                        }
                    }
                }
                if let takeaway = v.takeaway {
                    callout("Takeaway", takeaway, symbol: "lightbulb.fill")
                }
                Text(Self.footer(v)).font(.caption).foregroundStyle(.secondary)
            }
            if showsChat, let chat = v.conversationId {
                Button {
                    dismiss()
                    Task { await env.chat.open(id: chat) }
                } label: {
                    Label("Open the chat", systemImage: "bubble.left.and.bubble.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 32)
    }

    @ViewBuilder
    private func notReady(_ v: Video) -> some View {
        if v.status == "failed" {
            Label(v.error ?? "I couldn't read it.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text(v.step ?? "Waiting to start").foregroundStyle(.secondary)
            }
        }
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.secondary.opacity(0.16))
                .aspectRatio(16 / 9, contentMode: .fit)
            SkeletonBar(height: 22)
            SkeletonBar(width: 160, height: 12)
            ForEach(0..<4, id: \.self) { _ in SkeletonBar(height: 12) }
        }
        .shimmering()
        .padding(20)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.bold))
            content()
        }
    }

    private func callout(_ title: String, _ text: String, answer: String? = nil, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(answer == nil ? .body.weight(.medium) : .headline)
                .fixedSize(horizontal: false, vertical: true)
            if let answer {
                Text(answer).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func load() async {
        while !Task.isCancelled {
            do {
                let fresh = try await env.api.video(id)
                withAnimation(.snappy) { video = fresh }
                error = nil
                guard fresh.status == "queued" || fresh.status == "working" else { return }
            } catch {
                if video == nil { self.error = error.localizedDescription }
            }
            try? await Task.sleep(for: .seconds(4))
        }
    }

    static func byline(_ v: Video) -> String {
        var parts = [v.channel, v.duration.map { VideoCard.clock($0) }].compactMap { $0 }
        if let published = v.published, let date = try? Date(published, strategy: .iso8601.year().month().day()) {
            parts.append(date.formatted(.dateTime.day().month(.abbreviated).year()))
        }
        return parts.joined(separator: " · ")
    }

    static func footer(_ v: Video) -> String {
        let from = switch v.source {
        case "captions": "the video's captions"
        case "auto": "YouTube's automatic captions"
        case "whisper": "the audio, transcribed on your server"
        default: "the video"
        }
        let spoken = v.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        return "Written from \(from)" + (spoken.map { ", in \($0)" } ?? "") + "."
    }
}

struct ZoomTarget: Identifiable {
    let id = UUID()
    let image: UIImage
    let caption: String
}

/// A key moment on the page: the time (opens YouTube there) on a line down the side, the title and what happens,
/// and its frame when it has one.
private struct MomentRow: View {
    @EnvironmentObject private var env: AppEnvironment
    let moment: VideoMoment
    let last: Bool
    let zoom: (UIImage) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle().fill(Theme.accent).frame(width: 10, height: 10).padding(.top, 6)
                if !last { Rectangle().fill(Theme.line).frame(width: 2).padding(.top, 4) }
            }
            .frame(width: 12)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let url = URL(string: moment.url) {
                        Link(destination: url) {
                            Label(VideoCard.clock(moment.t), systemImage: "play.fill")
                                .labelStyle(TimeChipStyle())
                        }
                        .accessibilityLabel("Play from \(VideoCard.clock(moment.t))")
                    }
                    Text(moment.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                }
                Text(moment.text).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let frame = moment.frame {
                    ServerPhoto(id: frame)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onTapGesture { Task { await open(frame) } }
                        .accessibilityLabel("Frame at \(VideoCard.clock(moment.t))")
                        .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.bottom, last ? 0 : 22)
        }
    }

    private func open(_ frame: String) async {
        guard let data = try? await env.api.photo(frame), let image = UIImage(data: data) else { return }
        zoom(image)
    }
}

private struct TimeChipStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9, weight: .bold))
            configuration.title.font(.caption.weight(.bold)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.red.gradient, in: Capsule())
    }
}

// MARK: - Slides

/// The brief as a story: a cover, the answer to your question, a slide per key moment (its frame, or the time in
/// big type), and what to remember. Each one moves on by itself; tap the right or left to skip, hold to pause, drag
/// down to close.
struct VideoSlides: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let video: Video
    @State private var index = 0
    @State private var progress: Double = 0
    @State private var paused = false
    @State private var drag: CGFloat = 0

    private enum Slide: Hashable {
        case cover, answer, moment(VideoMoment), remember
    }

    private var slides: [Slide] {
        var all: [Slide] = [.cover]
        if video.question != nil, video.answer != nil { all.append(.answer) }
        all += video.keyMoments.map { .moment($0) }
        if video.takeaway != nil || !video.points.isEmpty { all.append(.remember) }
        return all
    }

    var body: some View {
        let all = slides
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            // Boxed to the screen, so a picture filling a slide's background can't make it wider.
            Color.clear
                .overlay { slide(all[min(index, all.count - 1)]) }
                .id(index)
                .transition(.opacity)
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture { step(-1, of: all.count) }
                Color.clear.contentShape(Rectangle()).onTapGesture { step(1, of: all.count) }
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
            }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.25).onChanged { _ in paused = true }
                .sequenced(before: DragGesture(minimumDistance: 0).onEnded { _ in paused = false }))
            bars(all.count)
        }
        .offset(y: max(0, drag))
        .gesture(DragGesture(minimumDistance: 30)
            .onChanged { drag = $0.translation.height }
            .onEnded { value in
                if value.translation.height > 120 { dismiss() } else { withAnimation(.snappy) { drag = 0 } }
            })
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task(id: index) { await run(count: all.count) }
    }

    // MARK: Moving on

    private func duration(_ slide: Slide) -> Double {
        switch slide {
        case .cover: 6
        case .answer: 9
        case .moment(let m): min(12, max(6, Double(m.text.count) / 22))
        case .remember: 14
        }
    }

    private func run(count: Int) async {
        progress = 0
        let length = duration(slides[min(index, count - 1)])
        let tick = 0.05
        while !Task.isCancelled && progress < 1 {
            try? await Task.sleep(for: .seconds(tick))
            if !paused { progress = min(1, progress + tick / length) }
        }
        guard !Task.isCancelled else { return }
        if index < count - 1 { withAnimation(.easeInOut(duration: 0.3)) { index += 1 } }
    }

    private func step(_ by: Int, of count: Int) {
        let next = index + by
        if next >= count { dismiss(); return }
        withAnimation(.easeInOut(duration: 0.25)) { index = max(0, next) }
        if next < 0 { progress = 0 }
    }

    private func bars(_ count: Int) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<count, id: \.self) { i in
                    GeometryReader { g in
                        Capsule().fill(.white.opacity(0.3))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white)
                                    .frame(width: g.size.width * (i < index ? 1 : i == index ? progress : 0))
                            }
                    }
                    .frame(height: 3)
                }
            }
            HStack(spacing: 10) {
                VideoThumbnailMini(video: video)
                VStack(alignment: .leading, spacing: 0) {
                    Text(video.title ?? "YouTube").font(.footnote.weight(.semibold)).lineLimit(1)
                    if let channel = video.channel {
                        Text(channel).font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    // MARK: The slides

    @ViewBuilder
    private func slide(_ slide: Slide) -> some View {
        switch slide {
        case .cover: cover
        case .answer: answer
        case .moment(let m): moment(m)
        case .remember: remember
        }
    }

    private var cover: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            VideoThumbnail(video: VideoCard(video), corner: 18)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
            Text(video.title ?? "").font(.largeTitle.weight(.bold)).minimumScaleFactor(0.6).lineLimit(4)
            if let gist = video.gist {
                Text(gist).font(.title3).foregroundStyle(.white.opacity(0.85)).minimumScaleFactor(0.7)
            }
            Spacer()
            Label("\(video.keyMoments.count) key moments", systemImage: "sparkles")
                .font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
        }
        .padding(24)
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            AsyncImage(url: video.thumbnailURL) { $0.resizable().scaledToFill() } placeholder: { Color.black }
                .blur(radius: 40).opacity(0.55).ignoresSafeArea()
        }
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Label("You asked", systemImage: "questionmark.bubble.fill")
                .font(.headline).foregroundStyle(.white.opacity(0.6))
            Text(video.question ?? "").font(.title.weight(.bold))
            Text(video.answer ?? "").font(.title3).foregroundStyle(.white.opacity(0.9)).minimumScaleFactor(0.6)
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Theme.slate, .black], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    @ViewBuilder
    private func moment(_ m: VideoMoment) -> some View {
        if let frame = m.frame {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 100)
                ServerPhoto(id: frame, fit: true)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 12) {
                    timeChip(m)
                    Text(m.title).font(.title.weight(.bold)).minimumScaleFactor(0.7)
                    Text(m.text).font(.title3).foregroundStyle(.white.opacity(0.85)).minimumScaleFactor(0.6)
                }
                .padding(24)
                Spacer(minLength: 20)
            }
            .background {
                ServerPhoto(id: frame).blur(radius: 50).opacity(0.35).ignoresSafeArea()
            }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                Spacer()
                Text(VideoCard.clock(m.t))
                    .font(.system(size: 76, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.18))
                Text(m.title).font(.largeTitle.weight(.bold)).minimumScaleFactor(0.6)
                Text(m.text).font(.title3).foregroundStyle(.white.opacity(0.88)).minimumScaleFactor(0.6)
                timeChip(m)
                Spacer()
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Theme.tint(for: m.title).opacity(0.55), .black],
                                       startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea())
        }
    }

    private func timeChip(_ m: VideoMoment) -> some View {
        Button { if let url = URL(string: m.url) { openURL(url) } } label: {
            Label("Watch from \(VideoCard.clock(m.t))", systemImage: "play.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.white.opacity(0.16), in: Capsule())
        }
        .foregroundStyle(.white)
    }

    private var remember: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 90)
            Label("Remember", systemImage: "lightbulb.fill").font(.headline).foregroundStyle(.yellow)
            if let takeaway = video.takeaway {
                Text(takeaway).font(.title.weight(.bold)).minimumScaleFactor(0.6)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(video.points.prefix(4).enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.yellow)
                        Text(point).font(.callout).foregroundStyle(.white.opacity(0.85)).lineLimit(4)
                    }
                }
            }
            .minimumScaleFactor(0.7)
            Spacer(minLength: 20)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Color(red: 0.2, green: 0.17, blue: 0.05), .black],
                                   startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }
}

private struct VideoThumbnailMini: View {
    let video: Video
    var body: some View {
        AsyncImage(url: video.thumbnailURL) { $0.resizable().scaledToFill() } placeholder: { Color.gray }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - Settings → Videos

/// Every video Aide has read, newest first, with search; a tap opens the brief, a swipe deletes it.
struct VideosView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var videos: [VideoCard]?
    @State private var search = ""
    @State private var error: String?
    @State private var page: VideoCard?

    var body: some View {
        List {
            if let videos {
                if videos.isEmpty {
                    ContentUnavailableView {
                        Label(search.isEmpty ? "No videos yet" : "No matches", systemImage: "play.rectangle")
                    } description: {
                        Text(search.isEmpty
                             ? "Share a YouTube video to Aide, or paste its link in a chat. The brief comes back in that chat and is kept here."
                             : "Nothing read matches \u{201C}\(search)\u{201D}.")
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(videos) { v in
                        Button { page = v } label: { VideoRow(video: v) }
                            .buttonStyle(.plain)
                    }
                    .onDelete { offsets in Task { await delete(offsets.map { videos[$0] }) } }
                }
            } else if let error {
                Text(error).foregroundStyle(.secondary)
            } else {
                ForEach(0..<4, id: \.self) { _ in SkeletonRow(mark: false) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Videos")
        .searchable(text: $search, prompt: "Search the videos")
        .task(id: search) {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(300)) } // typing
            guard !Task.isCancelled else { return }
            await load()
        }
        .refreshable { await load() }
        .sheet(item: $page, onDismiss: { Task { await load() } }) { v in VideoPage(id: v.id, showsChat: true).macCoverSize() }
    }

    #if DEBUG
    /// Simulator screenshots: `-previewSettings videos -previewVideo page` (or `slides`) opens the newest one.
    private var previewOpens: Bool { env.settings.isPreview && UserDefaults.standard.string(forKey: "previewVideo") != nil }
    #endif

    private func load() async {
        do {
            videos = try await env.api.videos(search: search.isEmpty ? nil : search).videos
            error = nil
            #if DEBUG
            if previewOpens, page == nil, let first = videos?.first(where: \.isReady) { page = first }
            #endif
        } catch {
            if videos == nil { self.error = error.localizedDescription }
        }
    }

    private func delete(_ gone: [VideoCard]) async {
        withAnimation { videos?.removeAll { v in gone.contains { $0.id == v.id } } }
        for v in gone { try? await env.api.deleteVideo(v.id) }
    }
}

private struct VideoRow: View {
    let video: VideoCard

    var body: some View {
        HStack(spacing: 12) {
            VideoThumbnail(video: video, corner: 8).frame(width: 112)
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title ?? "A YouTube video").font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(video.isFailed ? .orange : .secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if video.isWorking { return video.step ?? "Waiting to start" }
        if video.isFailed { return video.error ?? "Couldn't read it" }
        let day = video.date?.formatted(.dateTime.day().month(.abbreviated)) ?? ""
        return [video.channel, day].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
