import HealthKit

/// Reads Apple Health and sends the server one summary per day (docs/API.md, "Apple Health"). Raw samples
/// stay on the phone. Also sends the wake-up signal for the "I'm up" shortcut, and writes the habit counts logged
/// through Aide to Health's Inhaler Usage (`health_logged`, docs/API.md "Habits") and the meals as food entries
/// (docs/API.md "Food").
@MainActor
final class HealthService: ObservableObject {
    let isAvailable = HKHealthStore.isHealthDataAvailable()
    /// iOS has shown the permission sheet. Apps can't see which kinds were allowed, only that it was asked.
    @Published private(set) var hasAsked = false
    @Published private(set) var isUploading = false
    @Published private(set) var lastUpload: Date? {
        didSet { UserDefaults.standard.set(lastUpload, forKey: Keys.lastUpload) }
    }
    @Published private(set) var lastError: String?

    private enum Keys {
        static let backfilled = "healthBackfilled"
        static let lastUpload = "healthLastUpload"
    }

    /// Days sent the first time, so the server has baselines from the first morning.
    static let backfillDays = 60

    private let store = HKHealthStore()
    private let api: APIClient
    private var observing = false
    /// Another upload was asked for while one was running.
    private var uploadAgain = false
    private var isWriting = false
    /// Another write was asked for while one was running.
    private var writeAgain = false
    private var isWritingMeals = false
    private var writeMealsAgain = false

    init(api: APIClient) {
        self.api = api
        lastUpload = UserDefaults.standard.object(forKey: Keys.lastUpload) as? Date
    }

    private static let sleep = HKCategoryType(.sleepAnalysis)
    private static let restingHR = HKQuantityType(.restingHeartRate)
    private static let hrv = HKQuantityType(.heartRateVariabilitySDNN)
    private static let respiratory = HKQuantityType(.respiratoryRate)
    private static let wristTemp = HKQuantityType(.appleSleepingWristTemperature)
    private static let steps = HKQuantityType(.stepCount)
    private static let activeEnergy = HKQuantityType(.activeEnergyBurned)
    private static let exercise = HKQuantityType(.appleExerciseTime)
    private static let inhaler = HKQuantityType(.inhalerUsage)
    private static let energy = HKQuantityType(.dietaryEnergyConsumed)
    private static let bodyMass = HKQuantityType(.bodyMass)
    private static let height = HKQuantityType(.height)
    private static let vo2Max = HKQuantityType(.vo2Max)
    /// A workout's distance is the first of these it has.
    private static let distances = [HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling),
                                     HKQuantityType(.distanceSwimming)]
    /// What a meal is written as, each with the meal's number for it and its unit.
    private static let food: [(HKQuantityType, KeyPath<Meal, Int>, HKUnit)] = [
        (energy, \.calories, .kilocalorie()),
        (HKQuantityType(.dietaryProtein), \.proteinG, .gram()),
        (HKQuantityType(.dietaryCarbohydrates), \.carbsG, .gram()),
        (HKQuantityType(.dietaryFatTotal), \.fatG, .gram()),
        (HKQuantityType(.dietaryWater), \.waterMl, .literUnit(with: .milli)),
        (HKQuantityType(.dietaryCaffeine), \.caffeineMg, .gramUnit(with: .milli)),
    ]

    /// The food kinds are read too, so the app finds its own entries again. Weight, height, age, sex and VO2 max
    /// are for the food targets (the profile Coach proposes from).
    private static let readTypes: Set<HKObjectType> = Set([
        sleep, restingHR, hrv, respiratory, wristTemp, steps, activeEnergy, exercise, inhaler,
        HKObjectType.workoutType(), bodyMass, height, vo2Max,
        HKCharacteristicType(.dateOfBirth), HKCharacteristicType(.biologicalSex),
    ] + food.map(\.0) + distances)
    /// Inhaler Usage: a limit habit's counts logged through Aide are written there (the user logs coffees in it).
    /// The food kinds: every meal logged through Aide.
    private static let shareTypes: Set<HKSampleType> = Set([inhaler] + food.map(\.0))

    // MARK: Permission and background delivery

    func refreshStatus() async {
        guard isAvailable else { return }
        let status = try? await store.statusForAuthorizationRequest(toShare: Self.shareTypes, read: Self.readTypes)
        hasAsked = status == .unnecessary
    }

    func requestAccess() async {
        guard isAvailable else { return }
        do {
            try await store.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes)
            UserDefaults.standard.set(false, forKey: Keys.backfilled) // newly allowed kinds need their history
            await refreshStatus()
            await startObserving()
            _ = await upload()
            await writeMeals()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// At launch, so HealthKit can wake the app when the Watch syncs a night or a workout, or steps change.
    func startObserving() async {
        await refreshStatus()
        if !hasAsked, !observing, UserDefaults.standard.object(forKey: Keys.backfilled) != nil {
            // Allowed before, but there's a new kind to read or write (Inhaler Usage): ask; that comes back here.
            return await requestAccess()
        }
        guard hasAsked, !observing else { return }
        observing = true
        let watched: [(HKSampleType, HKUpdateFrequency)] = [
            (Self.sleep, .immediate), (HKObjectType.workoutType(), .immediate), (Self.steps, .hourly),
            (Self.inhaler, .immediate), // a limit habit counts from it, so it should show up soon
        ]
        for (type, frequency) in watched {
            try? await store.enableBackgroundDelivery(for: type, frequency: frequency)
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                guard error == nil else { return completion() }
                Task { @MainActor in
                    // Not calling completion makes HealthKit try again later, e.g. once the phone is unlocked.
                    if await self?.upload(days: 2) != .retry { completion() }
                }
            }
            store.execute(query)
        }
    }

    // MARK: Uploads

    enum UploadResult { case sent, skipped, retry }

    /// The last `days` days, or the backfill the first time. Launch, foreground and background delivery.
    @discardableResult
    func upload(days: Int = 7) async -> UploadResult {
        guard isAvailable, hasAsked else { return .skipped }
        if isUploading {
            uploadAgain = true
            return .sent
        }
        isUploading = true
        defer { isUploading = false }

        let backfilled = UserDefaults.standard.bool(forKey: Keys.backfilled)
        var result = await send(days: backfilled ? days : Self.backfillDays)
        if result == .sent { UserDefaults.standard.set(true, forKey: Keys.backfilled) }
        while uploadAgain, result == .sent {
            uploadAgain = false
            result = await send(days: days)
        }
        uploadAgain = false
        return result
    }

    private func send(days: Int) async -> UploadResult {
        do {
            let summaries = try await self.days(count: days)
            _ = try await api.uploadHealthDays(summaries)
            lastUpload = Date()
            lastError = nil
            return .sent
        } catch APIError.notConfigured {
            return .skipped
        } catch APIError.server(let status, _) where status == 404 {
            lastError = "The server doesn't take health data yet."
            return .skipped
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            return .retry // the phone is locked; Health data is encrypted until it's unlocked
        } catch {
            lastError = error.localizedDescription
            return .retry
        }
    }

    // MARK: Writing habit counts

    /// Makes the app's own Inhaler Usage samples on each of the last 60 days match what was logged through Aide
    /// (`health_logged` on habits that count from Health), adding or deleting only the app's samples, never the
    /// user's. After a count here, a `sync` push (an agent's or a widget's count) and on foreground.
    func writeLogged() async {
        guard isAvailable, hasAsked, store.authorizationStatus(for: Self.inhaler) == .sharingAuthorized else { return }
        if isWriting {
            writeAgain = true
            return
        }
        isWriting = true
        defer { isWriting = false }
        repeat {
            writeAgain = false
            do {
                if let days = try await write(api.habits()) { _ = await upload(days: days) }
            } catch {
                lastError = error.localizedDescription
                return
            }
        } while writeAgain
    }

    /// The days back the server's `health_logged` covers (a filled-in month included).
    private static let writeDays = 60

    /// How many days back Health changed (for the upload that follows), or nil if it didn't.
    private func write(_ habits: [Habit]) async throws -> Int? {
        guard habits.contains(where: { $0.health == "inhaler_usage" }) else { return nil }
        var wanted: [String: Int] = [:]
        for habit in habits where habit.health == "inhaler_usage" {
            for (day, count) in habit.healthLogged ?? [:] { wanted[day, default: 0] += count }
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let first = calendar.date(byAdding: .day, value: 1 - Self.writeDays, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        // One query for all the days, newest first within each.
        let byDay = Dictionary(grouping: try await ownInhalerSamples(from: first, to: end)) {
            calendar.startOfDay(for: $0.startDate)
        }
        var changed: Int?
        for back in 0..<Self.writeDays {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let own = byDay[day] ?? []
            let want = wanted[Wire.dayString(day)] ?? 0
            if own.count < want {
                let at = back == 0 ? Date() : calendar.date(byAdding: .hour, value: 12, to: day) ?? day
                let one = HKQuantity(unit: .count(), doubleValue: 1)
                try await store.save((own.count..<want).map { _ in
                    HKQuantitySample(type: Self.inhaler, quantity: one, start: at, end: at)
                })
                changed = back + 1
            } else if own.count > want {
                try await store.delete(Array(own.prefix(own.count - want)))
                changed = back + 1
            }
        }
        return changed.map { max($0, 7) }
    }

    private func ownInhalerSamples(from: Date, to: Date) async throws -> [HKQuantitySample] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate),
            HKQuery.predicateForObjects(from: .default()),
        ])
        let query = HKSampleQueryDescriptor(predicates: [.quantitySample(type: Self.inhaler, predicate: predicate)],
                                            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)])
        return try await query.result(for: store)
    }

    // MARK: Writing meals

    /// Meals are written for this many days back (the server's meals since then).
    private static let mealDays = 14

    private enum MealKey {
        static let id = "AideMeal"
        /// The meal's numbers and time, to see when it changed on the server.
        static let version = "AideMealVersion"
    }

    /// Makes the app's food entries in Health for the last `mealDays` days match the server's meals: a new meal
    /// is added, a changed one written again, a deleted one removed. Only the app's own entries are touched. After a
    /// log or an edit here, a `sync` push (a meal Coach logged in chat) and on foreground.
    func writeMeals() async {
        guard isAvailable, hasAsked, store.authorizationStatus(for: Self.energy) == .sharingAuthorized else { return }
        if isWritingMeals {
            writeMealsAgain = true
            return
        }
        isWritingMeals = true
        defer { isWritingMeals = false }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let first = calendar.date(byAdding: .day, value: 1 - Self.mealDays, to: today) else { return }
        repeat {
            writeMealsAgain = false
            do {
                try await write(meals: api.meals(from: first, to: today), since: first)
            } catch APIError.server(let status, _) where status == 404 {
                return // an older server without the meals read
            } catch APIError.notConfigured {
                return
            } catch {
                lastError = error.localizedDescription
                return
            }
        } while writeMealsAgain
    }

    private func write(meals: [Meal], since first: Date) async throws {
        let allowed = Self.food.filter { store.authorizationStatus(for: $0.0) == .sharingAuthorized }
        let own = try await ownMeals(since: first)
        var have: [Int: HKCorrelation] = [:]
        for entry in own {
            if let id = (entry.metadata?[MealKey.id] as? NSNumber)?.intValue, have[id] == nil {
                have[id] = entry
            } else {
                try await remove(entry) // a second entry for the same meal
            }
        }
        let wanted = Dictionary(meals.map { ($0.id, $0) }) { _, last in last }
        for (id, entry) in have where wanted[id] == nil {
            try await remove(entry)
        }
        for meal in meals {
            let version = Self.version(meal, allowed.map(\.0))
            if let entry = have[meal.id] {
                if entry.metadata?[MealKey.version] as? String == version { continue }
                try await remove(entry)
            }
            let at = meal.eatenDate ?? Date()
            let named: [String: Any] = [HKMetadataKeyFoodType: meal.name]
            var samples: Set<HKSample> = Set(allowed.compactMap { type, number, unit -> HKSample? in
                let value = meal[keyPath: number]
                guard value > 0 else { return nil }
                return HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: Double(value)),
                                        start: at, end: at, metadata: named)
            })
            if samples.isEmpty { // nothing but zeros: a correlation needs one sample, so 0 kcal
                samples = [HKQuantitySample(type: Self.energy, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: 0),
                                            start: at, end: at, metadata: named)]
            }
            let entry = HKCorrelation(type: HKCorrelationType(.food), start: at, end: at, objects: samples,
                                      metadata: [HKMetadataKeyFoodType: meal.name, MealKey.id: meal.id,
                                                 MealKey.version: version])
            try await store.save(entry)
        }
    }

    nonisolated static func version(_ meal: Meal, _ types: [HKQuantityType]) -> String {
        ([meal.name, meal.eatenAt] + [meal.calories, meal.proteinG, meal.carbsG, meal.fatG, meal.waterMl,
                                      meal.caffeineMg].map(String.init) + types.map(\.identifier))
            .joined(separator: "|")
    }

    /// The entry and what's in it (whether deleting a correlation takes its samples along isn't promised).
    private func remove(_ entry: HKCorrelation) async throws {
        try await store.delete(entry)
        for sample in entry.objects { try? await store.delete(sample) }
    }

    private func ownMeals(since: Date) async throws -> [HKCorrelation] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate),
            HKQuery.predicateForObjects(from: .default()),
        ])
        let query = HKSampleQueryDescriptor(predicates: [.correlation(type: HKCorrelationType(.food), predicate: predicate)],
                                            sortDescriptors: [SortDescriptor(\.startDate)])
        return try await query.result(for: store)
    }

    // MARK: Wake-up

    /// The "I'm up" shortcut: tell the server, with today's summary if Health can be read right now.
    /// Returns a line to show or say.
    func wake(source: String) async -> String {
        let today = await refreshedToday()
        do {
            let result = try await api.wake(WakeRequest(at: Wire.local(Date()), source: source, day: today))
            if result.started { return "Good morning. Your briefing is on its way." }
            switch result.reason {
            case "already": return "Your briefing already went out this morning."
            case "off": return "The wake-up briefing is off in Aide's digest settings."
            case "outside_hours": return "It's not morning, so there's no wake-up briefing."
            default: return "Aide didn't start a briefing."
            }
        } catch {
            return error.localizedDescription
        }
    }

    private func refreshedToday() async -> HealthDay? {
        await refreshStatus()
        guard isAvailable, hasAsked else { return nil }
        return try? await days(count: 1).first
    }

    // MARK: Reading HealthKit

    /// Summaries for the last `count` local days, today last.
    func days(count: Int) async throws -> [HealthDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let first = calendar.date(byAdding: .day, value: -(count - 1), to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today),
              let sleepFrom = calendar.date(byAdding: .hour, value: -18, to: first) // nights start the evening before
        else { return [] }

        async let sleepSamples = categorySamples(Self.sleep, from: sleepFrom, to: end)
        async let hrvSamples = quantitySamples(Self.hrv, from: sleepFrom, to: end)
        async let respiratorySamples = quantitySamples(Self.respiratory, from: sleepFrom, to: end)
        async let tempSamples = quantitySamples(Self.wristTemp, from: sleepFrom, to: end)
        async let workouts = workoutSamples(from: first, to: end)
        async let stepsByDay = daily(Self.steps, .cumulativeSum, from: first, to: end)
        async let energyByDay = daily(Self.activeEnergy, .cumulativeSum, from: first, to: end)
        async let exerciseByDay = daily(Self.exercise, .cumulativeSum, from: first, to: end)
        async let restingByDay = daily(Self.restingHR, .discreteAverage, from: first, to: end)
        async let inhalerByDay = daily(Self.inhaler, .cumulativeSum, from: first, to: end)
        async let weightSamples = quantitySamples(Self.bodyMass, from: first, to: end)
        async let vo2Samples = quantitySamples(Self.vo2Max, from: first, to: end)

        let segments = try await sleepSamples.compactMap(Self.segment)
        let (hrv, respiratory, temp) = try await (hrvSamples, respiratorySamples, tempSamples)
        let (allWorkouts, steps, energy, exercise, resting) =
            try await (workouts, stepsByDay, energyByDay, exerciseByDay, restingByDay)
        let inhaler = try await inhalerByDay
        let (weights, vo2) = try await (weightSamples, vo2Samples)
        let vo2Unit = HKUnit.literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .minute()))

        let bpm = HKUnit.count().unitDivided(by: .minute())
        return (0..<count).compactMap { offset -> HealthDay? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: first),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            let night = SleepSummary.night(endingOn: day, from: segments, calendar: calendar)
            let nightSpan = night.flatMap { n in n.bedtimeDate.flatMap { s in n.wakeDate.map { (s, $0) } } }

            var hrvMs = nightSpan.flatMap { Self.average(hrv, .secondUnit(with: .milli), $0.0, $0.1) }
            if hrvMs == nil { hrvMs = Self.average(hrv, .secondUnit(with: .milli), day, nextDay) }

            return HealthDay(
                date: Wire.dayString(day),
                sleep: night,
                restingHr: resting.statistics(for: day)?.averageQuantity().map { Int($0.doubleValue(for: bpm).rounded()) },
                hrvMs: hrvMs.map(Self.oneDecimal),
                respiratoryRate: nightSpan.flatMap { Self.average(respiratory, bpm, $0.0, $0.1) }.map(Self.oneDecimal),
                wristTempC: nightSpan.flatMap { Self.average(temp, .degreeCelsius(), $0.0, $0.1) }
                    .map { ($0 * 100).rounded() / 100 },
                steps: steps.statistics(for: day)?.sumQuantity().map { Int($0.doubleValue(for: .count())) },
                activeKcal: energy.statistics(for: day)?.sumQuantity().map { Int($0.doubleValue(for: .kilocalorie())) },
                exerciseMin: exercise.statistics(for: day)?.sumQuantity().map { Int($0.doubleValue(for: .minute())) },
                inhalerUsage: inhaler.statistics(for: day)?.sumQuantity().map { Int($0.doubleValue(for: .count())) },
                naps: Optional(SleepSummary.naps(on: day, from: segments, calendar: calendar)).flatMap { $0.isEmpty ? nil : $0 },
                workouts: allWorkouts.filter { $0.startDate >= day && $0.startDate < nextDay }.map(Self.workout),
                weightKg: Self.latest(weights, .gramUnit(with: .kilo), day, nextDay).map(Self.oneDecimal),
                vo2max: Self.latest(vo2, vo2Unit, day, nextDay).map(Self.oneDecimal)
            )
        }
    }

    private func categorySamples(_ type: HKCategoryType, from: Date, to: Date) async throws -> [HKCategorySample] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)
        let query = HKSampleQueryDescriptor(predicates: [.categorySample(type: type, predicate: predicate)],
                                            sortDescriptors: [SortDescriptor(\.startDate)])
        return try await query.result(for: store)
    }

    private func quantitySamples(_ type: HKQuantityType, from: Date, to: Date) async throws -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)
        let query = HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate)],
                                            sortDescriptors: [SortDescriptor(\.startDate)])
        return try await query.result(for: store)
    }

    private func workoutSamples(from: Date, to: Date) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)
        let query = HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: [SortDescriptor(\.startDate)])
        return try await query.result(for: store)
    }

    /// Per-day statistics; HealthKit removes the overlap between the iPhone and the Watch.
    private func daily(_ type: HKQuantityType, _ options: HKStatisticsOptions, from: Date, to: Date)
        async throws -> HKStatisticsCollection {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)
        let query = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate),
            options: options, anchorDate: from, intervalComponents: DateComponents(day: 1))
        return try await query.result(for: store)
    }

    private static func segment(_ sample: HKCategorySample) -> SleepSegment? {
        let stage: SleepSegment.Stage
        switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
        case .inBed: stage = .inBed
        case .awake: stage = .awake
        case .asleepUnspecified: stage = .asleep
        case .asleepCore: stage = .core
        case .asleepDeep: stage = .deep
        case .asleepREM: stage = .rem
        default: return nil
        }
        return SleepSegment(stage: stage, start: sample.startDate, end: sample.endDate)
    }

    /// Average of the samples that overlap `from`–`to`, or nil if there are none.
    private static func average(_ samples: [HKQuantitySample], _ unit: HKUnit, _ from: Date, _ to: Date) -> Double? {
        let values = samples.filter { $0.endDate > from && $0.startDate < to }.map { $0.quantity.doubleValue(for: unit) }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// The last sample that starts in `from`–`to`, or nil.
    private static func latest(_ samples: [HKQuantitySample], _ unit: HKUnit, _ from: Date, _ to: Date) -> Double? {
        samples.last { $0.startDate >= from && $0.startDate < to }?.quantity.doubleValue(for: unit)
    }

    private static func oneDecimal(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    /// What Health knows for the food targets' profile: the latest weight and height, age and sex; nil fields
    /// when it doesn't (or reading isn't allowed).
    func profile() async -> FoodProfile {
        var profile = FoodProfile()
        guard isAvailable else { return profile }
        let far = Date(timeIntervalSinceNow: -5 * 365 * 86400)
        if let w = try? await quantitySamples(Self.bodyMass, from: far, to: Date()).last {
            profile.weightKg = Self.oneDecimal(w.quantity.doubleValue(for: .gramUnit(with: .kilo)))
        }
        if let h = try? await quantitySamples(Self.height, from: far, to: Date()).last {
            profile.heightCm = Int(h.quantity.doubleValue(for: .meterUnit(with: .centi)).rounded())
        }
        if let born = try? store.dateOfBirthComponents().date {
            profile.age = Calendar.current.dateComponents([.year], from: born, to: Date()).year
        }
        switch try? store.biologicalSex().biologicalSex {
        case .male: profile.sex = "male"
        case .female: profile.sex = "female"
        default: break
        }
        return profile
    }

    private static func workout(_ w: HKWorkout) -> HealthWorkout {
        let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let meters = distances.lazy.compactMap { w.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }.first
        return HealthWorkout(id: w.uuid.uuidString, type: workoutType(w.workoutActivityType),
                             start: Wire.local(w.startDate), end: Wire.local(w.endDate),
                             minutes: Int((w.duration / 60).rounded()), kcal: kcal.map { Int($0.rounded()) },
                             km: meters.flatMap { $0 > 0 ? ($0 / 10).rounded() / 100 : nil })
    }

    /// HealthKit's activity types folded into the contract's list (docs/API.md, "Workout types").
    static func workoutType(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .traditionalStrengthTraining, .functionalStrengthTraining: "strength"
        case .running: "run"
        case .walking: "walk"
        case .hiking: "hike"
        case .cycling, .handCycling: "cycle"
        case .swimming, .waterFitness: "swim"
        case .highIntensityIntervalTraining: "hiit"
        case .yoga, .mindAndBody, .flexibility: "yoga"
        case .pilates: "pilates"
        case .coreTraining: "core"
        case .socialDance, .cardioDance, .barre: "dance"
        case .climbing: "climb"
        case .rowing, .paddleSports: "row"
        case .elliptical: "elliptical"
        case .stairs, .stairClimbing, .stepTraining: "stairs"
        case .mixedCardio, .jumpRope, .crossTraining: "cardio"
        case .martialArts, .boxing, .kickboxing, .wrestling, .taiChi: "martial_arts"
        case .soccer, .basketball, .tennis, .volleyball, .tableTennis, .badminton, .squash, .racquetball,
             .americanFootball, .rugby, .baseball, .softball, .hockey, .handball, .cricket, .lacrosse, .pickleball:
            "sport"
        default: "other"
        }
    }
}
