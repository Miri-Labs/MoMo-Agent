import Foundation
@preconcurrency import HealthKit
import Testing
import MoMoAgent
@testable import PhoneHealthChecks

@MainActor
private final class HealthStoreFixture: PhoneHealthStore {
    var available = true
    var needsAuthorization = false
    var authorizationError: HKError.Code?
    var requestedTypes: Set<HKObjectType> = []
    var values: [Date: Double] = [:]
    var intervals: [HealthSampleInterval] = []
    var errors: [String: HKError.Code] = [:]
    var delay: Duration = .zero
    var activeReads = 0
    var maximumReads = 0
    var executions = 0
    var stops = 0
    var onExecute: (() -> Void)?
    var onRead: (() -> Void)?
    func authorizationNeeded(for types: Set<HKObjectType>) -> Bool { needsAuthorization }
    func requestAccess(to types: Set<HKObjectType>) throws {
        if let authorizationError { throw NSError(domain: HKErrorDomain, code: authorizationError.rawValue) }
        requestedTypes = types; needsAuthorization = false
    }
    func execute(_ query: HKQuery) { executions += 1; onExecute?() }
    func stop(_ query: HKQuery) { stops += 1 }
    private func check(_ identifier: String) async throws {
        activeReads += 1; maximumReads = max(maximumReads, activeReads)
        defer { activeReads -= 1 }
        onRead?()
        if delay > .zero { try await Task.sleep(for: delay) }
        if let code = errors[identifier] { throw NSError(domain: HKErrorDomain, code: code.rawValue) }
    }
    func statistics(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, before: Date, anchor: Date, calendar: Calendar, options: HKStatisticsOptions, timeout: Duration) async throws -> [Date: Double] {
        try await check(identifier.rawValue)
        return identifier == .stepCount ? values : [:]
    }
    func heartRates(from: Date, before: Date, anchor: Date, calendar: Calendar, timeout: Duration) async throws -> [Date: HeartRateSummary] {
        try await check(HKQuantityTypeIdentifier.heartRate.rawValue)
        return [:]
    }
    func samples(type: HKSampleType, from: Date, before: Date, timeout: Duration) async throws -> [HealthSampleInterval] {
        try await check(type.identifier)
        return type == HKCategoryType(.sleepAnalysis) ? intervals : []
    }
}

private let healthStart = Date(timeIntervalSince1970: 57_600) // Local midnight in Shanghai.

@Test @MainActor func healthPartialFailureKeepsOtherMetricsAndQueriesInParallel() async throws {
    let store = HealthStoreFixture()
    store.values = [healthStart: 1234]
    store.errors[HKQuantityTypeIdentifier.heartRate.rawValue] = .errorAuthorizationNotDetermined
    store.errors[HKQuantityTypeIdentifier.restingHeartRate.rawValue] = .errorNoData
    store.delay = .milliseconds(25)
    store.intervals = [.init(start: healthStart, end: healthStart.addingTimeInterval(3600), duration: 3600)]
    let result = try await PhoneHealthContext(store: store).summarize(from: healthStart, before: healthStart.addingTimeInterval(86400), timezone: "Asia/Shanghai")
    #expect(result.availability == .connected)
    #expect(result.days.first?.steps == 1234)
    #expect(result.days.first?.asleepMinutes == 60)
    #expect(result.days.first?.restingHeartRateBPM == nil)
    #expect(result.issues?.count == 1)
    #expect(result.issues?.first?.metric == .heartRate)
    #expect(result.issues?.first?.reason == .authorizationRequired)
    #expect(store.maximumReads == 6 && store.activeReads == 0)
}

@Test @MainActor func healthNoDataIsNotAQueryFailureOrAZero() async throws {
    let store = HealthStoreFixture()
    for type in [HKQuantityTypeIdentifier.stepCount, .activeEnergyBurned, .heartRate, .restingHeartRate] {
        store.errors[type.rawValue] = .errorNoData
    }
    let result = try await PhoneHealthContext(store: store).summarize(from: healthStart, before: healthStart.addingTimeInterval(3600), timezone: "Asia/Shanghai")
    #expect(result.availability == .no_data_or_not_readable)
    #expect(result.issues == nil)
    #expect(result.days.allSatisfy { !$0.hasData })
}

@Test @MainActor func healthLockedDevicePreservesPerMetricErrorCodes() async throws {
    let store = HealthStoreFixture()
    let types: [HKSampleType] = [HKQuantityType(.stepCount), HKQuantityType(.activeEnergyBurned), HKQuantityType(.heartRate), HKQuantityType(.restingHeartRate), HKCategoryType(.sleepAnalysis), HKObjectType.workoutType()]
    for type in types { store.errors[type.identifier] = .errorDatabaseInaccessible }
    let result = try await PhoneHealthContext(store: store).summarize(from: healthStart, before: healthStart.addingTimeInterval(3600), timezone: "Asia/Shanghai")
    #expect(result.availability == .failed)
    #expect(result.issues?.count == 6)
    #expect(result.issues?.allSatisfy { $0.reason == .deviceLocked && $0.errorDomain == HKErrorDomain && $0.errorCode == HKError.Code.errorDatabaseInaccessible.rawValue } == true)
    #expect(result.days.allSatisfy { !$0.hasData })
}

@Test @MainActor func healthNewTypesShareTheSameAuthorizationSet() async throws {
    let store = HealthStoreFixture(); store.needsAuthorization = true
    let context = PhoneHealthContext(store: store)
    #expect(try await context.needsReadAuthorization())
    try await context.requestReadAccess()
    #expect(store.requestedTypes.count == 6)
    #expect(store.requestedTypes.contains(HKQuantityType(.heartRate)))
    #expect(store.requestedTypes.contains(HKQuantityType(.restingHeartRate)))
    #expect(try await !context.needsReadAuthorization())
    store.available = false
    #expect(try await context.summarize(from: healthStart, before: healthStart.addingTimeInterval(3600), timezone: "Asia/Shanghai").availability == .unavailable)
}

@Test @MainActor func healthUnknownErrorRetainsDiagnosticsWithoutPrivateDescription() throws {
    let issue = PhoneHealthContext.issue(for: NSError(domain: "fixture.health", code: 987, userInfo: [NSLocalizedDescriptionKey: "private sample content"]), metric: .sleep)
    #expect(issue.reason == .failed && issue.metric == .sleep)
    #expect(issue.errorDomain == "fixture.health" && issue.errorCode == 987)
    #expect(!String(decoding: try JSONEncoder().encode(issue), as: UTF8.self).contains("private sample content"))
}

@Test @MainActor func healthDismissingAuthorizationIsCancellationNotSettingsFailure() async throws {
    let store = HealthStoreFixture(); store.authorizationError = .errorUserCanceled
    await #expect(throws: SystemActionError.cancelled) { try await PhoneHealthContext(store: store).requestReadAccess() }
}

@Test @MainActor func healthCancellingSummaryCancelsAllMetricsInsteadOfReturningFailure() async throws {
    let store = HealthStoreFixture(); store.delay = .seconds(10)
    let started = AsyncStream<Void>.makeStream()
    store.onRead = { started.continuation.yield() }
    let task = Task { try await PhoneHealthContext(store: store).summarize(from: healthStart, before: healthStart.addingTimeInterval(3600), timezone: "Asia/Shanghai") }
    var iterator = started.stream.makeAsyncIterator()
    for _ in 0..<6 { _ = await iterator.next() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    started.continuation.finish()
    #expect(store.activeReads == 0)
}

@Test(arguments: [HKError.Code.errorHealthDataRestricted, .errorHealthDataUnavailable, .errorInvalidArgument])
@MainActor func healthMapsNativeErrorsWithoutTreatingThemAsDeniedReadPermissions(_ code: HKError.Code) {
    let issue = PhoneHealthContext.issue(for: NSError(domain: HKErrorDomain, code: code.rawValue), metric: .steps)
    let expected: HealthReadIssue.Reason = code == .errorHealthDataRestricted ? .restricted : (code == .errorHealthDataUnavailable ? .unavailable : .failed)
    #expect(issue.reason == expected && issue.errorCode == code.rawValue)
}

@MainActor private func emptyHealthQuery() -> HKQuery {
    HKStatisticsCollectionQuery(quantityType: HKQuantityType(.stepCount), quantitySamplePredicate: nil, options: .cumulativeSum, anchorDate: healthStart, intervalComponents: DateComponents(day: 1))
}

@Test @MainActor func healthQuerySuccessStopsOnceAndIgnoresDuplicateCallback() async throws {
    let store = HealthStoreFixture()
    let result = try await PhoneHealthQuery<Int>(store: store, timeout: .seconds(1)).run { finish in
        finish(.success(42)); finish(.success(99))
        return emptyHealthQuery()
    }
    #expect(result == 42 && store.executions == 1 && store.stops == 1)
}

@Test @MainActor func healthQueryTimeoutStopsAndLateCallbackCannotResumeAgain() async throws {
    let store = HealthStoreFixture()
    var callback: (@Sendable (Result<Int, any Error>) -> Void)?
    do {
        _ = try await PhoneHealthQuery<Int>(store: store, timeout: .milliseconds(20)).run { finish in
            callback = finish
            return emptyHealthQuery()
        }
        Issue.record("Expected a timeout")
    } catch let issue as HealthReadIssue { #expect(issue.reason == .timedOut) }
    callback?(.success(99))
    await Task.yield()
    #expect(store.executions == 1 && store.stops == 1)
}

@Test @MainActor func healthQueryCancellationStopsAnExecutingQuery() async throws {
    let store = HealthStoreFixture()
    let started = AsyncStream<Void>.makeStream()
    store.onExecute = { started.continuation.yield() }
    let task = Task { try await PhoneHealthQuery<Int>(store: store, timeout: .seconds(1)).run { _ in emptyHealthQuery() } }
    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    started.continuation.finish()
    #expect(store.executions == 1 && store.stops == 1)
}

@Test @MainActor func healthQueryCancelledBeforeStartDoesNotExecute() async throws {
    let store = HealthStoreFixture()
    let task = Task { try await PhoneHealthQuery<Int>(store: store, timeout: .seconds(1)).run { _ in emptyHealthQuery() } }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(store.executions == 0 && store.stops == 0)
}
