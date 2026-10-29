import SwiftUI

/// A barcode read in a meal photo (or typed), to open its sheet with; `photo` is the one it was read in.
struct ScannedCode: Identifiable {
    let code: String
    var photo: PickedPhoto?
    var id: String { code }
}

/// A photo with a barcode in it: the product and how much you had (empty is your usual portion, else one serving), then Log adds
/// it up on the server. A barcode nobody has yet asks for a photo of its nutrition facts, read once and saved, so
/// the next scan finds it.
struct ScanSheet: View {
    let barcode: String
    /// The day being looked at; nil is today.
    let date: String?
    /// The Coach chat it was scanned in; nil is the Food log.
    var conversation: String?
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
            Form {
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
                if let askCoach, phase != .reading {
                    Section {
                        Button("Ask Coach instead", systemImage: "bubble.left") {
                            askCoach()
                            dismiss()
                        }
                    } footer: {
                        Text("When the photo is a whole meal, not just this packet.")
                    }
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                        if phase == .looking { Button("Try again") { Task { await lookUp() } } }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle("Barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if case .found(let food, _) = phase {
                    ToolbarItem(placement: .confirmationAction) {
                        if saving {
                            ProgressView()
                        } else {
                            Button("Log") { Task { await log(food) } }
                                .disabled(amount == nil && food.defaultGrams == nil)
                        }
                    }
                }
            }
            .photoSources(camera: $showCamera, library: $showLibrary, limit: 1) { photos in
                if let photo = photos.first { Task { await read(photo) } }
            }
            .task { await lookUp() }
        }
        .presentationDetents([.medium, .large])
    }

    private func waiting(_ text: String) -> some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                Text(text).foregroundStyle(.secondary)
            }
        } footer: {
            Text(barcode).monospacedDigit()
        }
    }

    @ViewBuilder
    private func found(_ food: SavedFood, justRead: Bool) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(food.name).font(.headline)
                if !food.brand.isEmpty { Text(food.brand).font(.subheadline).foregroundStyle(.secondary) }
                Text("Per 100 g: \(Int(food.kcal100g.rounded())) kcal · P \(Self.g(food.protein100g)) · "
                     + "C \(Self.g(food.carbs100g)) · F \(Self.g(food.fat100g))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(.vertical, 2)
            if justRead {
                Button("Read the label again", systemImage: "camera") { phase = .missing }
            }
        } footer: {
            Text(justRead ? "Read off the label and saved for this barcode. Check the numbers against it."
                 : Self.origin(food.source))
        }
        Section {
            HStack {
                TextField(food.defaultGrams.map { Self.g($0) } ?? "Grams", text: $grams)
                    .keyboardType(.decimalPad)
                    .focused($gramsFocused)
                if Arithmetic.isSum(grams) {
                    Text(amount.map { "= \(Self.g($0))" } ?? "?").foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("g").foregroundStyle(.secondary)
                }
            }
            .toolbar {
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
            if let g = amount ?? food.defaultGrams {
                let p = food.portion(g)
                Text("\(p.calories) kcal · P \(p.protein) g · C \(p.carbs) g · F \(p.fat) g")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        } header: {
            Text("How much?")
        } footer: {
            let sums = "Sums work too: 400/3 for a third of a 400 g pack, 2×30 for two biscuits."
            if let usual = food.usualG {
                Text("Empty is your usual \(Self.g(usual)). \(sums)")
            } else if let serving = food.servingG {
                Text("Empty is one serving, \(Self.g(serving)). \(sums)")
            } else {
                Text("The packet gives no serving size, so say how much. \(sums)")
            }
        }
        .onAppear { if food.defaultGrams == nil { gramsFocused = true } }
    }

    private var missing: some View {
        Group {
            Section {
                Text("Nobody has this barcode yet. Take a photo of the nutrition facts (valori nutrizionali) on the "
                     + "packet: Aide reads it once and remembers it for the next scan.")
                    .font(.subheadline)
                TextField("What is it? (optional)", text: $name)
            } footer: {
                Text(barcode).monospacedDigit()
            }
            Section {
                if CameraPicker.isAvailable {
                    Button("Take photo of the label", systemImage: "camera") { showCamera = true }
                }
                Button("Choose a photo", systemImage: "photo.on.rectangle") { showLibrary = true }
            }
        }
    }

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

    /// 15 g, 12.5 g.
    static func g(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1)))) g"
    }

    static func origin(_ source: String) -> String {
        switch source {
        case "off": "From Open Food Facts."
        case "label": "Read off its label."
        case "web": "From the web."
        case "user": "As you told Coach."
        default: "Coach's estimate."
        }
    }
}
