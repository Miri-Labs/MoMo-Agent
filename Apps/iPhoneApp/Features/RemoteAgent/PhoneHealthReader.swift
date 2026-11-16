import Foundation
import HealthKit
import MoMoAgentClient

struct PhoneHealthReadResult: Sendable {
    var observations: [HealthSnapshot.Observation] = []
    var sleepSessions: [HealthSnapshot.SleepSession] = []
    var workouts: [HealthSnapshot.WorkoutSummary] = []
    var activitySummaries: [HealthSnapshot.ActivityRingSummary] = []
}

@MainActor
protocol PhoneHealthReading {
    var available: Bool { get }
    func authorize() async throws
    func read(now: Date, start: Date, calendar: Calendar) async throws -> [HealthSnapshot.Observation]
    func readSnapshot(now: Date, start: Date, calendar: Calendar) async throws -> PhoneHealthReadResult
}

extension PhoneHealthReading {
    func readSnapshot(now: Date, start: Date, calendar: Calendar) async throws -> PhoneHealthReadResult {
        let observations = try await read(now: now, start: start, calendar: calendar)
        return PhoneHealthReadResult(observations: observations)
    }
}

@MainActor
final class PhoneHealthReader: PhoneHealthReading {
    private let store = HKHealthStore()
    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    private struct CumulativeSpec {
        let metric: String
        let type: HKQuantityType
        let hkUnit: HKUnit
        let unitLabel: String
    }

    private struct VitalSpec {
        let metric: String
        let type: HKQuantityType
        let hkUnit: HKUnit
        let unitLabel: String
        let scale: Double
        let includeDailyAverage: Bool
    }

    private struct RawSleepSample: Sendable {
        enum Stage: Sendable {
            case inBed, awake, deep, core, rem, asleepUnspecified
        }
        let stage: Stage
        let start: Double
        let end: Double
        let sourceName: String
        let sourceBundle: String
    }

    private var cumulativeSpecs: [CumulativeSpec] {
        [
            .init(metric: "steps", type: HKQuantityType(.stepCount), hkUnit: .count(), unitLabel: "count"),
            .init(metric: "active_energy", type: HKQuantityType(.activeEnergyBurned), hkUnit: .kilocalorie(), unitLabel: "kcal"),
            .init(metric: "distance_walking_running", type: HKQuantityType(.distanceWalkingRunning), hkUnit: .meter(), unitLabel: "m"),
            .init(metric: "flights_climbed", type: HKQuantityType(.flightsClimbed), hkUnit: .count(), unitLabel: "count"),
        ]
    }

    private var vitalSpecs: [VitalSpec] {
        var list: [VitalSpec] = [
            .init(metric: "heart_rate", type: HKQuantityType(.heartRate),
                  hkUnit: .count().unitDivided(by: .minute()), unitLabel: "count/min", scale: 1.0, includeDailyAverage: false),
            .init(metric: "resting_heart_rate", type: HKQuantityType(.restingHeartRate),
                  hkUnit: .count().unitDivided(by: .minute()), unitLabel: "count/min", scale: 1.0, includeDailyAverage: true),
            .init(metric: "hrv_sdnn", type: HKQuantityType(.heartRateVariabilitySDNN),
                  hkUnit: .secondUnit(with: .milli), unitLabel: "ms", scale: 1.0, includeDailyAverage: true),
            .init(metric: "oxygen_saturation", type: HKQuantityType(.oxygenSaturation),
                  hkUnit: .percent(), unitLabel: "%", scale: 100.0, includeDailyAverage: false),
            .init(metric: "respiratory_rate", type: HKQuantityType(.respiratoryRate),
                  hkUnit: .count().unitDivided(by: .minute()), unitLabel: "count/min", scale: 1.0, includeDailyAverage: false),
            .init(metric: "vo2_max", type: HKQuantityType(.vo2Max),
                  hkUnit: HKUnit.literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .minute())),
                  unitLabel: "mL/kg/min", scale: 1.0, includeDailyAverage: false),
            .init(metric: "environmental_audio_exposure", type: HKQuantityType(.environmentalAudioExposure),
                  hkUnit: .decibelAWeightedSoundPressureLevel(), unitLabel: "dBASPL", scale: 1.0, includeDailyAverage: false),
            .init(metric: "headphone_audio_exposure", type: HKQuantityType(.headphoneAudioExposure),
                  hkUnit: .decibelAWeightedSoundPressureLevel(), unitLabel: "dBASPL", scale: 1.0, includeDailyAverage: false),
        ]
        if #available(iOS 16.0, *) {
            list.append(.init(
                metric: "wrist_temperature",
                type: HKQuantityType(.appleSleepingWristTemperature),
                hkUnit: .degreeCelsius(),
                unitLabel: "degC",
                scale: 1.0,
                includeDailyAverage: false
            ))
        }
        return list
    }

    private var allReadTypes: Set<HKObjectType> {
        var set = Set<HKObjectType>()
        for spec in cumulativeSpecs { set.insert(spec.type) }
        for spec in vitalSpecs { set.insert(spec.type) }
        set.insert(HKCategoryType(.sleepAnalysis))
        set.insert(HKObjectType.workoutType())
        set.insert(HKObjectType.activitySummaryType())
        return set
    }

    func authorize() async throws {
        // Completion means the sheet completed, not that read access was granted.
        try await store.requestAuthorization(toShare: [], read: allReadTypes)
    }

    func read(now: Date, start: Date, calendar: Calendar) async throws -> [HealthSnapshot.Observation] {
        try await readSnapshot(now: now, start: start, calendar: calendar).observations
    }

    func readSnapshot(now: Date, start: Date, calendar: Calendar) async throws -> PhoneHealthReadResult {
        var observations: [HealthSnapshot.Observation] = []

        // 1. Daily cumulative metrics per local calendar day.
        var day = start
        var dayWindows: [(start: Date, end: Date)] = []
        while day < now {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            dayWindows.append((day, min(next, now)))
            day = next
        }

        for spec in cumulativeSpecs {
            for window in dayWindows {
                try Task.checkCancellation()
                if let total = try await queryStatistic(
                    type: spec.type,
                    unit: spec.hkUnit,
                    options: .cumulativeSum,
                    from: window.start,
                    to: window.end
                ), total.isFinite {
                    observations.append(.init(
                        metric: spec.metric,
                        unit: spec.unitLabel,
                        value: total,
                        start: window.start,
                        end: window.end,
                        sourceName: "Apple Health · 每日合计",
                        sourceBundle: "com.apple.Health"
                    ))
                }
            }
        }

        // 2. Latest sample + optional daily discrete averages for vitals & audio exposure.
        for spec in vitalSpecs {
            try Task.checkCancellation()
            if let latest = try await queryLatestObservation(spec: spec, from: start, to: now) {
                observations.append(latest)
            }
            if spec.includeDailyAverage {
                for window in dayWindows {
                    try Task.checkCancellation()
                    if let avg = try await queryStatistic(
                        type: spec.type,
                        unit: spec.hkUnit,
                        options: .discreteAverage,
                        from: window.start,
                        to: window.end,
                        average: true
                    ), avg.isFinite {
                        observations.append(.init(
                            metric: spec.metric,
                            unit: spec.unitLabel,
                            value: avg * spec.scale,
                            start: window.start,
                            end: window.end,
                            sourceName: "Apple Health · 每日均值",
                            sourceBundle: "com.apple.Health.daily_avg"
                        ))
                    }
                }
            }
        }

        if observations.count > 150 {
            observations = Array(observations.suffix(150))
        }

        // 3. Sleep sessions (<= 21).
        try Task.checkCancellation()
        let sleepSessions = try await querySleepSessions(from: start, to: now)

        // 4. Workouts (<= 40).
        try Task.checkCancellation()
        let workouts = try await queryWorkouts(from: start, to: now)

        // 5. Activity Ring Summaries (7 days).
        try Task.checkCancellation()
        let activitySummaries = try await queryActivitySummaries(from: start, to: now, calendar: calendar)

        return PhoneHealthReadResult(
            observations: observations,
            sleepSessions: sleepSessions,
            workouts: workouts,
            activitySummaries: activitySummaries
        )
    }

    private nonisolated static func shouldRethrow(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let hkError = error as? HKError {
            return hkError.code == .errorDatabaseInaccessible
        }
        let nsError = error as NSError
        if nsError.domain == HKErrorDomain, nsError.code == HKError.Code.errorDatabaseInaccessible.rawValue {
            return true
        }
        return false
    }

    private func queryStatistic(
        type: HKQuantityType,
        unit: HKUnit,
        options: HKStatisticsOptions,
        from start: Date,
        to end: Date,
        average: Bool = false
    ) async throws -> Double? {
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
                let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: options) { _, statistics, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        let quantity = average ? statistics?.averageQuantity() : statistics?.sumQuantity()
                        continuation.resume(returning: quantity?.doubleValue(for: unit))
                    }
                }
                store.execute(query)
            }
        } catch {
            if Self.shouldRethrow(error) { throw error }
            return nil
        }
    }

    private func queryLatestObservation(spec: VitalSpec, from start: Date, to end: Date) async throws -> HealthSnapshot.Observation? {
        let hkUnit = spec.hkUnit
        let metric = spec.metric
        let unitLabel = spec.unitLabel
        let scale = spec.scale
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
                let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
                let query = HKSampleQuery(sampleType: spec.type, predicate: predicate, limit: 1, sortDescriptors: [sort]) { _, samples, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let sample = samples?.first as? HKQuantitySample else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let rawValue = sample.quantity.doubleValue(for: hkUnit) * scale
                    guard rawValue.isFinite else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let clampedStart = max(start, min(end, sample.startDate))
                    let clampedEnd = max(clampedStart, min(end, sample.endDate))
                    let obs = HealthSnapshot.Observation(
                        metric: metric,
                        unit: unitLabel,
                        value: rawValue,
                        start: clampedStart,
                        end: clampedEnd,
                        sourceName: sample.sourceRevision.source.name,
                        sourceBundle: sample.sourceRevision.source.bundleIdentifier
                    )
                    continuation.resume(returning: obs)
                }
                store.execute(query)
            }
        } catch {
            if Self.shouldRethrow(error) { throw error }
            return nil
        }
    }

    private func querySleepSessions(from start: Date, to end: Date) async throws -> [HealthSnapshot.SleepSession] {
        let sleepType = HKCategoryType(.sleepAnalysis)
        let rawSamples: [RawSleepSample]
        do {
            rawSamples = try await withCheckedThrowingContinuation { continuation in
                let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
                let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
                let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: 2000, sortDescriptors: [sort]) { _, samples, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let categorySamples = (samples as? [HKCategorySample]) ?? []
                    let mapped: [RawSleepSample] = categorySamples.compactMap { sample in
                        guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { return nil }
                        let stage: RawSleepSample.Stage
                        switch value {
                        case .inBed: stage = .inBed
                        case .awake: stage = .awake
                        case .asleepDeep: stage = .deep
                        case .asleepCore: stage = .core
                        case .asleepREM: stage = .rem
                        case .asleepUnspecified: stage = .asleepUnspecified
                        @unknown default: stage = .asleepUnspecified
                        }
                        return RawSleepSample(
                            stage: stage,
                            start: sample.startDate.timeIntervalSince1970,
                            end: sample.endDate.timeIntervalSince1970,
                            sourceName: sample.sourceRevision.source.name,
                            sourceBundle: sample.sourceRevision.source.bundleIdentifier
                        )
                    }
                    continuation.resume(returning: mapped)
                }
                store.execute(query)
            }
        } catch {
            if Self.shouldRethrow(error) { throw error }
            return []
        }

        return Self.groupSleepSessions(rawSamples, windowStart: start.timeIntervalSince1970, windowEnd: end.timeIntervalSince1970)
    }

    private nonisolated static func groupSleepSessions(
        _ samples: [RawSleepSample],
        windowStart: Double,
        windowEnd: Double
    ) -> [HealthSnapshot.SleepSession] {
        let clamped: [RawSleepSample] = samples.compactMap { s in
            let a = max(windowStart, s.start)
            let b = min(windowEnd, s.end)
            guard a.isFinite, b.isFinite, b > a else { return nil }
            return RawSleepSample(stage: s.stage, start: a, end: b, sourceName: s.sourceName, sourceBundle: s.sourceBundle)
        }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        guard !clamped.isEmpty else { return [] }

        var clusters: [[RawSleepSample]] = []
        var currentCluster: [RawSleepSample] = []
        var clusterMaxEnd: Double = -.infinity
        let maxGapSeconds: Double = 45 * 60

        for sample in clamped {
            if currentCluster.isEmpty || sample.start - clusterMaxEnd <= maxGapSeconds {
                currentCluster.append(sample)
                clusterMaxEnd = max(clusterMaxEnd, sample.end)
            } else {
                clusters.append(currentCluster)
                currentCluster = [sample]
                clusterMaxEnd = sample.end
            }
        }
        if !currentCluster.isEmpty { clusters.append(currentCluster) }

        var sessions: [HealthSnapshot.SleepSession] = []
        for cluster in clusters {
            guard let sessionStart = cluster.map(\.start).min(),
                  let sessionEnd = cluster.map(\.end).max(),
                  sessionEnd > sessionStart else { continue }

            var deepIntervals: [(Double, Double)] = []
            var coreIntervals: [(Double, Double)] = []
            var remIntervals: [(Double, Double)] = []
            var unspecIntervals: [(Double, Double)] = []
            var awakeIntervals: [(Double, Double)] = []
            var inBedIntervals: [(Double, Double)] = []
            var sourceSleepWeights: [String: (name: String, bundle: String, seconds: Double)] = [:]

            for item in cluster {
                let pair = (item.start, item.end)
                switch item.stage {
                case .deep: deepIntervals.append(pair)
                case .core: coreIntervals.append(pair)
                case .rem: remIntervals.append(pair)
                case .asleepUnspecified: unspecIntervals.append(pair)
                case .awake: awakeIntervals.append(pair)
                case .inBed: inBedIntervals.append(pair)
                }
                let weight = (item.stage == .inBed || item.stage == .awake) ? (item.end - item.start) * 0.1 : (item.end - item.start)
                let key = "\(item.sourceBundle)|\(item.sourceName)"
                var entry = sourceSleepWeights[key] ?? (item.sourceName, item.sourceBundle, 0)
                entry.seconds += weight
                sourceSleepWeights[key] = entry
            }

            let deepSeconds = mergedDuration(deepIntervals)
            let coreSeconds = mergedDuration(coreIntervals)
            let remSeconds = mergedDuration(remIntervals)
            let awakeSeconds = mergedDuration(awakeIntervals)
            let allAsleepIntervals = deepIntervals + coreIntervals + remIntervals + unspecIntervals
            let asleepSeconds = mergedDuration(allAsleepIntervals)
            let inBedSeconds = mergedDuration(inBedIntervals + allAsleepIntervals + awakeIntervals)

            guard asleepSeconds > 0 || inBedSeconds > 0 else { continue }
            let dominantSource = sourceSleepWeights.values.max(by: { $0.seconds < $1.seconds })
                ?? (cluster[0].sourceName, cluster[0].sourceBundle, 0)

            sessions.append(.init(
                id: "sleep-\(Int(sessionStart))-\(Int(sessionEnd))",
                start: sessionStart,
                end: sessionEnd,
                asleepSeconds: asleepSeconds,
                inBedSeconds: inBedSeconds,
                deepSeconds: deepSeconds,
                coreSeconds: coreSeconds,
                remSeconds: remSeconds,
                awakeSeconds: awakeSeconds,
                sourceName: dominantSource.name,
                sourceBundle: dominantSource.bundle
            ))
        }

        if sessions.count > 21 {
            sessions = Array(sessions.suffix(21))
        }
        return sessions
    }

    private nonisolated static func mergedDuration(_ intervals: [(Double, Double)]) -> Double {
        let valid = intervals.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        guard let first = valid.first else { return 0 }
        var total: Double = 0
        var curStart = first.0
        var curEnd = first.1
        for interval in valid.dropFirst() {
            if interval.0 <= curEnd {
                curEnd = max(curEnd, interval.1)
            } else {
                total += curEnd - curStart
                curStart = interval.0
                curEnd = interval.1
            }
        }
        total += curEnd - curStart
        return total
    }

    private func queryWorkouts(from start: Date, to end: Date) async throws -> [HealthSnapshot.WorkoutSummary] {
        do {
            let fetched: [HealthSnapshot.WorkoutSummary] = try await withCheckedThrowingContinuation { continuation in
                let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
                let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
                let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: 40, sortDescriptors: [sort]) { _, samples, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let workouts = (samples as? [HKWorkout]) ?? []
                    let energyType = HKQuantityType(.activeEnergyBurned)
                    let summaries: [HealthSnapshot.WorkoutSummary] = workouts.map { workout in
                        let energy = workout.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie())
                        let distance = workout.totalDistance?.doubleValue(for: .meter())
                        let wStart = workout.startDate.timeIntervalSince1970
                        let wEnd = max(wStart, min(end.timeIntervalSince1970 + 30, workout.endDate.timeIntervalSince1970))
                        return HealthSnapshot.WorkoutSummary(
                            id: workout.uuid.uuidString.lowercased(),
                            activityType: Self.workoutActivityIdentifier(workout.workoutActivityType),
                            start: wStart,
                            end: wEnd,
                            durationSeconds: max(0, workout.duration),
                            activeEnergyKcal: (energy?.isFinite == true && energy! >= 0) ? energy : nil,
                            distanceMeters: (distance?.isFinite == true && distance! > 0) ? distance : nil,
                            sourceName: workout.sourceRevision.source.name,
                            sourceBundle: workout.sourceRevision.source.bundleIdentifier
                        )
                    }
                    continuation.resume(returning: summaries.sorted { $0.start < $1.start })
                }
                store.execute(query)
            }
            return fetched
        } catch {
            if Self.shouldRethrow(error) { throw error }
            return []
        }
    }

    private func queryActivitySummaries(
        from start: Date,
        to end: Date,
        calendar: Calendar
    ) async throws -> [HealthSnapshot.ActivityRingSummary] {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        var startComponents = gregorian.dateComponents([.era, .year, .month, .day], from: start)
        startComponents.calendar = gregorian
        var endComponents = gregorian.dateComponents([.era, .year, .month, .day], from: end)
        endComponents.calendar = gregorian
        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: startComponents, end: endComponents)
        let queryCalendar = gregorian

        do {
            return try await withCheckedThrowingContinuation { continuation in
                let query = HKActivitySummaryQuery(predicate: predicate) { _, summaries, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let mapped: [HealthSnapshot.ActivityRingSummary] = (summaries ?? []).compactMap { summary in
                        let comps = summary.dateComponents(for: queryCalendar)
                        guard let year = comps.year, let month = comps.month, let day = comps.day else { return nil }
                        let dateString = String(format: "%04d-%02d-%02d", year, month, day)
                        let activeEnergy = summary.activeEnergyBurned.doubleValue(for: .kilocalorie())
                        let activeEnergyGoal = summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie())
                        let exercise = summary.appleExerciseTime.doubleValue(for: .minute())
                        let exerciseGoal = summary.exerciseTimeGoal?.doubleValue(for: .minute()) ?? 0
                        let stand = summary.appleStandHours.doubleValue(for: .count())
                        let standGoal = summary.standHoursGoal?.doubleValue(for: .count()) ?? 0
                        return HealthSnapshot.ActivityRingSummary(
                            date: dateString,
                            activeEnergyKcal: max(0, activeEnergy),
                            activeEnergyGoalKcal: max(0, activeEnergyGoal),
                            exerciseMinutes: max(0, exercise),
                            exerciseGoalMinutes: max(0, exerciseGoal),
                            standHours: max(0, stand),
                            standGoalHours: max(0, standGoal)
                        )
                    }.sorted { $0.date < $1.date }
                    continuation.resume(returning: Array(mapped.suffix(7)))
                }
                store.execute(query)
            }
        } catch {
            if Self.shouldRethrow(error) { throw error }
            return []
        }
    }

    private nonisolated static func workoutActivityIdentifier(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .climbing: return "climbing"
        case .running: return "running"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .traditionalStrengthTraining: return "traditional_strength_training"
        case .functionalStrengthTraining: return "functional_strength_training"
        case .coreTraining: return "core_training"
        case .yoga: return "yoga"
        case .pilates: return "pilates"
        case .swimming: return "swimming"
        case .hiking: return "hiking"
        case .highIntensityIntervalTraining: return "high_intensity_interval_training"
        case .elliptical: return "elliptical"
        case .rowing: return "rowing"
        case .stairClimbing: return "stair_climbing"
        case .stairs: return "stairs"
        case .stepTraining: return "step_training"
        case .jumpRope: return "jump_rope"
        case .cardioDance, .socialDance: return "dance"
        case .cooldown: return "cooldown"
        case .flexibility: return "flexibility"
        case .mindAndBody: return "mind_and_body"
        case .tennis: return "tennis"
        case .tableTennis: return "table_tennis"
        case .badminton: return "badminton"
        case .pickleball: return "pickleball"
        case .squash: return "squash"
        case .basketball: return "basketball"
        case .soccer: return "soccer"
        case .volleyball: return "volleyball"
        case .baseball: return "baseball"
        case .golf: return "golf"
        case .snowboarding: return "snowboarding"
        case .downhillSkiing, .crossCountrySkiing: return "skiing"
        case .skatingSports: return "skating"
        case .surfingSports: return "surfing"
        case .paddleSports: return "paddle_sports"
        case .martialArts: return "martial_arts"
        case .boxing, .kickboxing: return "boxing"
        case .mixedCardio: return "mixed_cardio"
        case .crossTraining: return "cross_training"
        case .other: return "other"
        default: return "other"
        }
    }
}
