import Foundation
import HealthKit
import MoMoAgentClient

@MainActor
protocol PhoneHealthReading {
    var available: Bool { get }
    func authorize() async throws
    func read(now: Date, start: Date, calendar: Calendar) async throws -> [HealthSnapshot.Observation]
}

@MainActor
final class PhoneHealthReader: PhoneHealthReading {
    private let store = HKHealthStore()
    var available: Bool { HKHealthStore.isHealthDataAvailable() }
    private let steps = HKQuantityType(.stepCount)
    private let heartRate = HKQuantityType(.heartRate)

    func authorize() async throws {
        // Completion means the sheet completed, not that read access was granted.
        try await store.requestAuthorization(toShare: [], read: [steps, heartRate])
    }

    func read(now: Date, start: Date, calendar: Calendar) async throws -> [HealthSnapshot.Observation] {
        var result: [HealthSnapshot.Observation] = []
        var day = start
        while day < now {
            try Task.checkCancellation()
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let end = min(next, now)
            let total = try await steps(from: day, to: end)
            if let total {
                result.append(.init(metric: "steps", unit: "count", value: total, start: day, end: end,
                                    sourceName: "Apple Health · 每日合计", sourceBundle: "com.apple.Health"))
            }
            day = next
        }
        if let sample = try await latestHeartRate(from: start, to: now) {
            result.append(.init(metric: "heart_rate", unit: "count/min", value: sample.quantity.doubleValue(for: .count().unitDivided(by: .minute())),
                                start: sample.startDate, end: sample.endDate, sourceName: sample.sourceRevision.source.name,
                                sourceBundle: sample.sourceRevision.source.bundleIdentifier))
        }
        return result
    }

    private func steps(from start: Date, to end: Date) async throws -> Double? {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKStatisticsQuery(quantityType: steps, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: .count())) }
            }
            store.execute(query)
        }
    }

    private func latestHeartRate(from start: Date, to end: Date) async throws -> HKQuantitySample? {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
            let query = HKSampleQuery(sampleType: heartRate, predicate: predicate, limit: 1,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples?.first as? HKQuantitySample) }
            }
            store.execute(query)
        }
    }
}
