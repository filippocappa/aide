import SwiftUI

/// A barcode read in a meal photo (or typed), to open its sheet with; `photo` is the one it was read in.
struct ScannedCode: Identifiable {
    let code: String
    var photo: PickedPhoto?
    var id: String { code }
}

/// A packet's barcode: the product, how much you had (your usual portion to start with, else one serving), what that
/// comes to, then Log adds it up on the server with no model call. A barcode nobody has yet asks for a photo of its
/// nutrition facts, read once and saved, so the next scan finds it.
struct ScanSheet: View {
    let barcode: String
    /// The day being looked at; nil is today.
    let date: String?
    /// The Coach chat it was scanned in; nil is the Food log.
    var conversation: String?
    /// Coach's colour, for the numbers.
    var tint: Color = Theme.accent
    /// After logging: the meal, to say so and reload.
    let logged: (Meal) -> Void
    /// The photo goes to Coach instead (there's more in it than the packet); nil when there's no photo.
    var askCoach: (() -> Void)?
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case looking
        case found(SavedFood, justRead: Bool)
        case missing
        case reading
    }

    @State private var phase = Phase.looking
    @State private var grams = ""
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false
    @State private var showCamera = false
    @State private var showLibrary = false
    @FocusState private var gramsFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch phase {
                    case .looking:
                        waiting("Looking it up…")
                    case .reading:
                        waiting("Reading the label…")
                    case .found(let food, let justRead):
                        found(food, justRead: justRead)
                    case .missing:
                        missing
                    }
                    if let error {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                            if phase == .looking { Button("Try again") { Task { await lookUp() } }.font(.footnote.weight(.semibold)) }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .animation(.easeOut(duration: 0.2), value: phase)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.grouped)
            .safeAreaInset(edge: .bottom) { bottomBar }
            .navigationTitle(phase == .missing ? "" : "Packet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                // The number pad has no + − × ÷: a 400 g pack split in 3 is "400/3".
                ToolbarItemGroup(placement: .keyboard) {
                    if gramsFocused {
                        ForEach(["+", "−", "×", "÷", "(", ")"], id: \.self) { key in
                            Button(key) { grams += key }
                                .font(.title3.weight(.medium))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .photoSources(camera: $showCamera, library: $showLibrary, limit: 1) { photos in
                if let photo = photos.first { Task { await read(photo) } }
            }
            .task { await lookUp() }
        }
        .presentationDetents([.large])
        .presentationCornerRadius(28)
    }

    // MARK: Looking it up

    private func waiting(_ text: String) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
            Text(barcode).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: Found

    @ViewBuilder
    private func found(_ food: SavedFood, justRead: Bool) -> some View {
        product(food, justRead: justRead)
        howMuch(food)
        if let g = amount ?? food.defaultGrams {
            comesTo(food.portion(g), grams: g)
        }
    }

    /// The name, the brand, its Nutri-Score and whether it's ultra-processed.
    private func product(_ food: SavedFood, justRead: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(food.name).font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                if !food.brand.isEmpty { Text(food.brand).font(.subheadline).foregroundStyle(.secondary) }
                HStack(spacing: 6) {
                    if food.nova == 4 {
                        Text("Ultra-processed")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.orange.opacity(0.14), in: Capsule())
                    }
                    Text((justRead ? "Read off the label just now" : Self.origin(food.source)) + " · \(barcode)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
                if justRead {
                    Button("Read the label again", systemImage: "camera") { phase = .missing }
                        .font(.footnote.weight(.semibold))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            if let grade = food.grade { GradeTile(grade: grade) }
        }
        .padding(.top, 8)
    }

    /// A big number of grams, and the portions it can be in one tap.
    private func howMuch(_ food: SavedFood) -> some View {
        VStack(spacing: 14) {
            Text("How much?").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TextField("0", text: $grams)
                    .keyboardType(.decimalPad)
                    .focused($gramsFocused)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .fixedSize()
                    .accessibilityLabel("Grams")
                Text("g").font(.title.weight(.semibold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { gramsFocused = true }
            if Arithmetic.isSum(grams) {
                Text(amount.map { "= \(Self.g($0))" } ?? "Not a sum yet")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.portions(food), id: \.grams) { portion in
                        chip(portion.label, grams: portion.grams)
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollClipDisabled()
            Text(food.defaultGrams == nil
                 ? "The packet gives no serving size, so say how much. Sums work: 400/3 is a third of a 400 g pack."
                 : "Sums work: 400/3 is a third of a 400 g pack, 2×30 two biscuits.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onAppear {
            if grams.isEmpty, let g = food.defaultGrams { grams = Self.number(g) }
            if food.defaultGrams == nil { gramsFocused = true }
        }
    }

    private func chip(_ label: String, grams value: Double) -> some View {
        let on = amount.map { abs($0 - value) < 0.05 } ?? false
        return Button {
            grams = Self.number(value)
            gramsFocused = false
        } label: {
            VStack(spacing: 1) {
                Text(label).font(.caption.weight(.semibold))
                Text(Self.g(value)).font(.caption2).monospacedDigit().opacity(0.75)
            }
            .foregroundStyle(on ? Theme.onAccent : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(on ? Theme.accent : Theme.chip, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// What the grams come to: the calories big, the macros as three small bars.
    private func comesTo(_ p: (calories: Int, protein: Int, carbs: Int, fat: Int), grams: Double) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(p.calories)")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                Text("kcal").font(.headline).foregroundStyle(.secondary)
                Spacer()
                Text("in \(Self.g(grams))").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 12) {
                macro("Protein", grams: p.protein, kcal: 4, of: p.calories, color: tint)
                macro("Carbs", grams: p.carbs, kcal: 4, of: p.calories, color: tint)
                macro("Fat", grams: p.fat, kcal: 9, of: p.calories, color: tint)
            }
        }
        .padding(18)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.snappy, value: p.calories)
    }

    /// One macro's grams over a bar of its share of the calories.
    private func macro(_ name: String, grams: Int, kcal: Double, of calories: Int, color: Color) -> some View {
        let share = calories > 0 ? min(1, Double(grams) * kcal / Double(calories)) : 0
        return VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text("\(grams) g").font(.headline).monospacedDigit().contentTransition(.numericText())
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.18))
                    Capsule().fill(color).frame(width: max(4, geo.size.width * share))
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Nobody has it

    private var missing: some View {
        VStack(spacing: 16) {
            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 76, height: 76)
                .background(tint.opacity(0.14), in: Circle())
                .padding(.top, 24)
            VStack(spacing: 4) {
                Text("New to Aide").font(.title2.weight(.bold))
                Text("Barcode \(barcode)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Text("Take a photo of the nutrition facts (valori nutrizionali) on the packet. Aide reads it once and "
                 + "remembers it for the next scan.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TextField("What is it? (optional)", text: $name)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(Theme.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: The bottom

    @ViewBuilder
    private var bottomBar: some View {
        let bar = VStack(spacing: 10) {
            switch phase {
            case .found(let food, _):
                let g = amount ?? food.defaultGrams
                primary(saving ? "Logging…" : g.map { "Log \(food.portion($0).calories) kcal" } ?? "Say how much",
                        disabled: g == nil || saving) {
                    Task { await log(food) }
                }
            case .missing:
                if CameraPicker.isAvailable {
                    primary("Photograph the label", symbol: "camera.fill") { showCamera = true }
                }
                secondary("Choose a photo", symbol: "photo.on.rectangle") { showLibrary = true }
            case .looking, .reading:
                EmptyView()
            }
            if let askCoach, phase != .reading {
                secondary("It's a whole meal: ask Coach", symbol: "bubble.left") {
                    askCoach()
                    dismiss()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        if phase == .looking && askCoach == nil {
            EmptyView()
        } else {
            bar.background(Theme.grouped.opacity(0.94).ignoresSafeArea())
        }
    }

    private func primary(_ title: String, symbol: String? = nil, disabled: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol) }
                Text(title).contentTransition(.numericText())
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Theme.accent.opacity(disabled ? 0.4 : 1), in: Capsule())
        }
        .disabled(disabled)
    }

    private func secondary(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .tint(.primary)
    }

    // MARK: Work

    /// The grams typed, a number or a sum ("400/3"), with a comma or a point; nil when empty or not one.
    private var amount: Double? {
        Arithmetic.evaluate(grams).flatMap { $0 > 0 ? $0 : nil }
    }

    private func lookUp() async {
        phase = .looking
        error = nil
        do {
            phase = try await env.api.food(barcode: barcode).map { .found($0, justRead: false) } ?? .missing
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func read(_ photo: PickedPhoto) async {
        phase = .reading
        error = nil
        do {
            let id = try await env.api.uploadPhoto(photo.jpeg)
            let words = name.trimmingCharacters(in: .whitespacesAndNewlines)
            phase = .found(try await env.api.readLabel(LabelRequest(barcode: barcode, photo: id, name: words)),
                           justRead: true)
        } catch {
            phase = .missing
            self.error = error.localizedDescription
        }
    }

    private func log(_ food: SavedFood) async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            let meal = try await env.api.logFood(food.id, FoodPortion(grams: amount, date: date, conversationId: conversation))
            logged(meal)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The portions a tap away: your usual, one or two servings, and 100 g, each once.
    static func portions(_ food: SavedFood) -> [(label: String, grams: Double)] {
        var out: [(label: String, grams: Double)] = []
        func add(_ label: String, _ grams: Double?) {
            guard let grams, grams > 0, !out.contains(where: { abs($0.grams - grams) < 0.05 }) else { return }
            out.append((label, grams))
        }
        add("Your usual", food.usualG)
        add("1 serving", food.servingG)
        add("2 servings", food.servingG.map { $0 * 2 })
        add("100 g", 100)
        return out
    }

    /// 15, 12.5: for the field.
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
    }

    /// 15 g, 12.5 g.
    static func g(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1)))) g"
    }

    static func origin(_ source: String) -> String {
        switch source {
        case "off": "From Open Food Facts"
        case "label": "Read off its label"
        case "web": "From the web"
        case "user": "As you told Coach"
        default: "Coach's estimate"
        }
    }
}

/// Nutri-Score's letter on its own colour, as the packets show it.
struct GradeTile: View {
    let grade: String

    var body: some View {
        VStack(spacing: 2) {
            Text(grade.uppercased())
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Grade.color(grade), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("Nutri-Score").font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nutri-Score \(grade.uppercased())")
    }
}
