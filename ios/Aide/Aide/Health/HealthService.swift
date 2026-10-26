import HealthKit

/// Reads Apple Health and sends the server one summary per day (docs/API.md, "Apple Health"). Raw samples
/// stay on the phone. Also sends the wake-up signal for the "I'm up" shortcut.
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

    private static let readTypes: Set<HKObjectType> = [
        sleep, restingHR, hrv, respiratory, wristTemp, steps, activeEnergy, exercise, inhaler,
        HKObjectType.workoutType(),
    ]

    // MARK: Permission and background delivery

    func refreshStatus() async {
        guard isAvailable else { return }
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes)
        hasAsked = status == .unnecessary
    }

    func requestAccess() async {
        guard isAvailable else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: Self.readTypes)
            UserDefaults.standard.set(false, forKey: Keys.backfilled) // newly allowed kinds need their history
            await refreshStatus()
            await startObserving()
            _ = await upload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// At launch, so HealthKit can wake the app when the Watch syncs a night or a workout, or steps change.
    func startObserving() async {
        await refreshStatus()
        if !hasAsked, !observing, UserDefaults.standard.object(forKey: Keys.backfilled) != nil {
            // Allowed before, but there's a new kind to read (Inhaler Usage): ask for it; that comes back here.
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

        let segments = try await sleepSamples.compactMap(Self.segment)
        let (hrv, respiratory, temp) = try await (hrvSamples, respiratorySamples, tempSamples)
        let (allWorkouts, steps, energy, exercise, resting) =
            try await (workouts, stepsByDay, energyByDay, exerciseByDay, restingByDay)
        let inhaler = try await inhalerByDay

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
                workouts: allWorkouts.filter { $0.startDate >= day && $0.startDate < nextDay }.map(Self.workout)
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

    private static func oneDecimal(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    private static func workout(_ w: HKWorkout) -> HealthWorkout {
        let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        return HealthWorkout(id: w.uuid.uuidString, type: workoutType(w.workoutActivityType),
                             start: Wire.local(w.startDate), end: Wire.local(w.endDate),
                             minutes: Int((w.duration / 60).rounded()), kcal: kcal.map { Int($0.rounded()) })
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
