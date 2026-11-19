import CoreLocation
import CoreMotion
import CryptoKit
import EventKit
import Foundation
import MoMoAgentClient

/// EventKit is read-only here. Visits use the system's low-power arrival/departure service.
@MainActor final class PhoneSourcesReader: NSObject, PhoneSourcesReading, CLLocationManagerDelegate {
    var onChange: (() -> Void)?
    private let events = EKEventStore()
    private let location = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let motion = CMMotionActivityManager()
    private let file: URL
    private var visits: [PhoneSourceSnapshot.Record] = []
    private var enabled = false
    private var locationFailed = false
    private var visitAccessWaiter: CheckedContinuation<Void, Error>?
    private static let alwaysPromptedKey = "momo.location.didRequestAlwaysAuthorization"
    enum ReadError: Error { case denied, unavailable, tooManyRecords }

    private struct RawMotionSample: Sendable {
        let start: Double
        let kind: String
        let confidence: String
        let confidenceRank: Int
    }

    init(directory: URL) throws {
        file = directory.appendingPathComponent("phone-visits.json")
        if FileManager.default.fileExists(atPath: file.path) {
            visits = try JSONDecoder().decode([PhoneSourceSnapshot.Record].self, from: Data(contentsOf: file))
        }
        super.init()
        location.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(eventsChanged), name: .EKEventStoreChanged, object: events)
    }
    @objc nonisolated private func eventsChanged() { Task { @MainActor [weak self] in self?.onChange?() } }

    func canPromptAuthorization(_ kind: PhoneSourceKind) -> Bool {
        switch kind {
        case .visits:
            return location.authorizationStatus == .notDetermined
        case .calendar:
            return EKEventStore.authorizationStatus(for: .event) == .notDetermined
        case .reminders:
            return EKEventStore.authorizationStatus(for: .reminder) == .notDetermined
        case .motion:
            return CMMotionActivityManager.isActivityAvailable() && CMMotionActivityManager.authorizationStatus() == .notDetermined
        }
    }

    func authorization(_ kind: PhoneSourceKind) -> String {
        switch kind {
        case .visits:
            if locationFailed { return "temporarily_unavailable" }
            switch location.authorizationStatus {
            case .authorizedAlways: return "enabled"
            case .authorizedWhenInUse: return "foreground_only"
            default: return "needs_permission"
            }
        case .calendar:
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess ? "enabled" : "needs_permission"
        case .reminders:
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess ? "enabled" : "needs_permission"
        case .motion:
            guard CMMotionActivityManager.isActivityAvailable() else { return "unavailable" }
            switch CMMotionActivityManager.authorizationStatus() {
            case .authorized: return "enabled"
            case .notDetermined, .denied, .restricted: return "needs_permission"
            @unknown default: return "needs_permission"
            }
        }
    }
    func authorize(_ kind: PhoneSourceKind) async throws {
        switch kind {
        case .calendar:
            guard try await events.requestFullAccessToEvents() else { throw ReadError.denied }
        case .reminders:
            guard try await events.requestFullAccessToReminders() else { throw ReadError.denied }
        case .visits:
            locationFailed = false
            switch location.authorizationStatus {
            case .notDetermined:
                try await withCheckedThrowingContinuation { continuation in
                    visitAccessWaiter = continuation
                    location.requestWhenInUseAuthorization()
                }
            case .authorizedWhenInUse, .authorizedAlways: break
            default: throw ReadError.denied
            }
        case .motion:
            guard CMMotionActivityManager.isActivityAvailable() else { throw ReadError.unavailable }
            let status = CMMotionActivityManager.authorizationStatus()
            if status == .denied || status == .restricted { throw ReadError.denied }
            let now = Date()
            _ = try await queryMotionSamples(from: now.addingTimeInterval(-86400), to: now)
            guard CMMotionActivityManager.authorizationStatus() == .authorized else { throw ReadError.denied }
        }
    }
    func canPromptBackgroundVisits() -> Bool {
        location.authorizationStatus == .authorizedWhenInUse
            && !UserDefaults.standard.bool(forKey: Self.alwaysPromptedKey)
    }
    func requestBackgroundVisits() {
        guard enabled && location.authorizationStatus == .authorizedWhenInUse else { return }
        UserDefaults.standard.set(true, forKey: Self.alwaysPromptedKey)
        location.requestAlwaysAuthorization()
    }
    func setVisitsEnabled(_ value: Bool) throws {
        enabled = value
        if enabled {
            locationFailed = false
            updateMonitoring()
        } else {
            location.stopMonitoringVisits()
            location.stopMonitoringSignificantLocationChanges()
            geocoder.cancelGeocode()
            visits = []
            try saveVisits()
        }
    }
    private func updateMonitoring() {
        if enabled && ["enabled", "foreground_only"].contains(authorization(.visits)) {
            location.startMonitoringVisits()
            if CLLocationManager.significantLocationChangeMonitoringAvailable() {
                location.startMonitoringSignificantLocationChanges()
            }
            let latestStart = visits.compactMap(\.start).max() ?? 0
            if visits.isEmpty || Date().timeIntervalSince1970 - latestStart > 1800 {
                location.requestLocation()
            }
        } else {
            location.stopMonitoringVisits()
            location.stopMonitoringSignificantLocationChanges()
        }
    }
    func read(_ kind: PhoneSourceKind, from: Date, to: Date) async throws -> [PhoneSourceSnapshot.Record] {
        if kind == .visits {
            locationFailed = false
            if enabled { updateMonitoring() }
        }
        guard ["enabled", "foreground_only"].contains(authorization(kind)) else { throw ReadError.denied }
        let values: [PhoneSourceSnapshot.Record]
        switch kind {
        case .visits:
            pruneVisits()
            try saveVisits()
            values = visits
        case .calendar:
            let predicate = events.predicateForEvents(withStart: from, end: to, calendars: nil)
            values = events.events(matching: predicate).map { event in
                .init(id: Self.digest(event.calendarItemIdentifier + ":" + String(event.startDate.timeIntervalSince1970)),
                      title: event.title ?? "", sourceName: event.calendar.title,
                      start: event.startDate.timeIntervalSince1970, end: event.endDate.timeIntervalSince1970, allDay: event.isAllDay)
            }
        case .reminders:
            // Include overdue and undated incomplete items; do not imply a seven-day due-date filter.
            let predicate = events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            let result: [PhoneSourceSnapshot.Record]? = await withCheckedContinuation { continuation in
                events.fetchReminders(matching: predicate) { reminders in
                    // Copy EventKit objects on their callback queue; only Sendable values cross actors.
                    continuation.resume(returning: reminders?.map(Self.reminderRecord))
                }
            }
            try Task.checkCancellation()
            guard authorization(kind) == "enabled" else { throw ReadError.denied }
            guard let result else { throw ReadError.unavailable }
            values = result
        case .motion:
            guard CMMotionActivityManager.isActivityAvailable() else { throw ReadError.unavailable }
            guard CMMotionActivityManager.authorizationStatus() == .authorized else { throw ReadError.denied }
            let windowEnd = to
            let windowStart = max(from, windowEnd.addingTimeInterval(-86400))
            let rawSamples = try await queryMotionSamples(from: windowStart, to: windowEnd)
            try Task.checkCancellation()
            guard authorization(.motion) == "enabled" else { throw ReadError.denied }
            values = Self.mergeMotionSamples(rawSamples, windowStart: windowStart.timeIntervalSince1970, windowEnd: windowEnd.timeIntervalSince1970)
        }
        // Refuse an oversized snapshot rather than silently dropping user data.
        guard values.count <= 2000, values.allSatisfy({ ($0.title?.utf8.count ?? 0) <= 8192 && $0.sourceName.utf8.count <= 1024 }) else {
            throw ReadError.tooManyRecords
        }
        return values.sorted { ($0.start ?? 0, $0.id) < ($1.start ?? 0, $1.id) }
    }

    private func queryMotionSamples(from start: Date, to end: Date) async throws -> [RawMotionSample] {
        try await withCheckedThrowingContinuation { continuation in
            motion.queryActivityStarting(from: start, to: end, to: .main) { activities, error in
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == CMErrorDomain,
                       nsError.code == Int(CMErrorMotionActivityNotAuthorized.rawValue) {
                        continuation.resume(throwing: ReadError.denied)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                let mapped = (activities ?? []).map(Self.rawMotionSample)
                continuation.resume(returning: mapped)
            }
        }
    }

    private nonisolated static func rawMotionSample(_ activity: CMMotionActivity) -> RawMotionSample {
        let kind: String
        if activity.automotive { kind = "automotive" }
        else if activity.cycling { kind = "cycling" }
        else if activity.running { kind = "running" }
        else if activity.walking { kind = "walking" }
        else if activity.stationary { kind = "stationary" }
        else { kind = "unknown" }

        let confidence: String
        let rank: Int
        switch activity.confidence {
        case .high: confidence = "high"; rank = 2
        case .medium: confidence = "medium"; rank = 1
        case .low: confidence = "low"; rank = 0
        @unknown default: confidence = "low"; rank = 0
        }
        return RawMotionSample(
            start: activity.startDate.timeIntervalSince1970,
            kind: kind,
            confidence: confidence,
            confidenceRank: rank
        )
    }

    private nonisolated static func mergeMotionSamples(
        _ samples: [RawMotionSample],
        windowStart: Double,
        windowEnd: Double
    ) -> [PhoneSourceSnapshot.Record] {
        guard !samples.isEmpty, windowEnd > windowStart else { return [] }
        let sorted = samples.filter { $0.start.isFinite }.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return [] }

        struct Segment {
            var kind: String
            var start: Double
            var end: Double
            var confidenceDurations: [String: Double]
        }

        var segments: [Segment] = []
        for index in sorted.indices {
            let current = sorted[index]
            let rawEnd = index + 1 < sorted.count ? sorted[index + 1].start : windowEnd
            let segStart = max(windowStart, current.start)
            let segEnd = min(windowEnd, rawEnd)
            guard segEnd > segStart else { continue }
            let duration = segEnd - segStart

            // Ignore ultra-brief (< 45s) low-confidence or unknown blips.
            if (current.confidenceRank == 0 || current.kind == "unknown") && duration < 45 {
                if !segments.isEmpty {
                    segments[segments.count - 1].end = max(segments[segments.count - 1].end, segEnd)
                }
                continue
            }

            if var last = segments.last, last.kind == current.kind, segStart - last.end <= 60 {
                last.end = max(last.end, segEnd)
                last.confidenceDurations[current.confidence, default: 0] += duration
                segments[segments.count - 1] = last
            } else {
                segments.append(Segment(
                    kind: current.kind,
                    start: segStart,
                    end: segEnd,
                    confidenceDurations: [current.confidence: duration]
                ))
            }
        }

        if segments.count > 180 {
            segments = Array(segments.suffix(180))
        }

        var usedIDs = Set<String>()
        return segments.map { seg in
            let highDur = seg.confidenceDurations["high", default: 0]
            let medDur = seg.confidenceDurations["medium", default: 0]
            let lowDur = seg.confidenceDurations["low", default: 0]
            let conf: String
            if highDur >= medDur && highDur >= lowDur && highDur > 0 { conf = "high" }
            else if medDur >= lowDur && medDur > 0 { conf = "medium" }
            else { conf = "low" }

            var baseSec = Int(seg.start)
            var candidateID = "motion-\(baseSec)-\(seg.kind)"
            while !usedIDs.insert(candidateID).inserted {
                baseSec += 1
                candidateID = "motion-\(baseSec)-\(seg.kind)"
            }
            return PhoneSourceSnapshot.Record(
                id: candidateID,
                title: seg.kind,
                sourceName: "CoreMotion confidence:\(conf)",
                start: seg.start,
                end: seg.end
            )
        }
    }
    private nonisolated static func reminderRecord(_ reminder: EKReminder) -> PhoneSourceSnapshot.Record {
        let due = reminder.dueDateComponents.flatMap { ($0.calendar ?? Calendar.current).date(from: $0)?.timeIntervalSince1970 }
        return .init(id: digest(reminder.calendarItemIdentifier), title: reminder.title ?? "", sourceName: reminder.calendar.title,
                     start: due, allDay: reminder.dueDateComponents.map { $0.hour == nil })
    }
    private nonisolated static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func saveVisits() throws {
        try JSONEncoder().encode(visits).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func pruneVisits() {
        let cutoff = Date.now.addingTimeInterval(-7 * 86400).timeIntervalSince1970
        visits.removeAll { ($0.end ?? $0.start ?? 0) < cutoff }
        visits.sort { ($0.start ?? $0.end ?? 0) < ($1.start ?? $1.end ?? 0) }
        var excess = max(0, visits.count - 1800)
        visits.removeAll { record in
            guard excess > 0, record.sourceName == "CoreLocation significant_change" else { return false }
            excess -= 1
            return true
        }
        if visits.count > 1800 { visits.removeFirst(visits.count - 1800) }
    }
    private func enrichVisit(_ record: PhoneSourceSnapshot.Record) async {
        guard enabled, !geocoder.isGeocoding, let latitude = record.latitude, let longitude = record.longitude else { return }
        do {
            let places = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude))
            guard enabled, let index = visits.firstIndex(where: { $0.id == record.id }), let place = places.first else { return }
            let name = Self.formatVisitPlace(place)
            guard !name.isEmpty else { return }
            visits[index].title = name
            try saveVisits(); onChange?()
        } catch {
            // The visit's coordinates and times remain available when address lookup is offline.
        }
    }
    private nonisolated static func formatVisitPlace(_ place: CLPlacemark) -> String {
        let aoi = place.areasOfInterest?.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let subLocality = place.subLocality?.trimmingCharacters(in: .whitespacesAndNewlines)
        let locality = place.locality?.trimmingCharacters(in: .whitespacesAndNewlines)
        let admin = place.administrativeArea?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let aoi, !aoi.isEmpty {
            if let subLocality, !subLocality.isEmpty, !aoi.contains(subLocality) {
                return "\(subLocality) · \(aoi)"
            }
            return aoi
        }
        if var rawName = place.name?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty {
            for prefix in [admin, locality].compactMap({ $0 }) where !prefix.isEmpty && rawName.count > prefix.count {
                if rawName.hasPrefix(prefix) { rawName.removeFirst(prefix.count) }
            }
            rawName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawName.isEmpty {
                if let subLocality, !subLocality.isEmpty, !rawName.contains(subLocality) {
                    return "\(subLocality) · \(rawName)"
                }
                return rawName
            }
        }
        return [locality, subLocality, place.thoroughfare].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            locationFailed = false
            if location.authorizationStatus != .notDetermined, let waiter = visitAccessWaiter {
                visitAccessWaiter = nil
                if ["enabled", "foreground_only"].contains(authorization(.visits)) { waiter.resume() }
                else { waiter.resume(throwing: ReadError.denied) }
            }
            if authorization(.visits) == "needs_permission" {
                geocoder.cancelGeocode(); visits = []
                do { try saveVisits() } catch { locationFailed = true }
            }
            updateMonitoring(); onChange?()
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let latitude = visit.coordinate.latitude, longitude = visit.coordinate.longitude, accuracy = visit.horizontalAccuracy
        let arrival = visit.arrivalDate == .distantPast ? nil : visit.arrivalDate.timeIntervalSince1970
        let departure = visit.departureDate == .distantFuture ? nil : visit.departureDate.timeIntervalSince1970
        Task { @MainActor [weak self] in
            guard let self, enabled, [.authorizedAlways, .authorizedWhenInUse].contains(location.authorizationStatus),
                  (-90...90).contains(latitude), (-180...180).contains(longitude), accuracy.isFinite, accuracy >= 0,
                  arrival != nil || departure != nil else { return }
            locationFailed = false
            let id = Self.digest("\(latitude):\(longitude):\(arrival ?? departure!)")
            let existingTitle = visits.first(where: { $0.id == id })?.title
            let record = PhoneSourceSnapshot.Record(id: id, title: existingTitle, sourceName: "CoreLocation visits",
                                                    start: arrival, end: departure,
                                                    latitude: latitude, longitude: longitude, accuracy: accuracy)
            visits.removeAll { $0.id == id }; visits.append(record); pruneVisits()
            do { try saveVisits() } catch { locationFailed = true }
            onChange?()
            if existingTitle == nil { await enrichVisit(record) }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let records = locations.compactMap { fix -> PhoneSourceSnapshot.Record? in
            let latitude = fix.coordinate.latitude, longitude = fix.coordinate.longitude
            let timestamp = fix.timestamp.timeIntervalSince1970
            guard CLLocationCoordinate2DIsValid(fix.coordinate), latitude.isFinite, longitude.isFinite,
                  timestamp.isFinite, fix.horizontalAccuracy.isFinite, (0...500).contains(fix.horizontalAccuracy) else { return nil }
            return .init(id: Self.digest("sig:\(latitude):\(longitude):\(timestamp)"), title: nil,
                         sourceName: "CoreLocation significant_change", start: timestamp, end: timestamp,
                         latitude: latitude, longitude: longitude, accuracy: fix.horizontalAccuracy)
        }.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
        Task { @MainActor [weak self] in
            guard let self, enabled, !records.isEmpty,
                  [.authorizedAlways, .authorizedWhenInUse].contains(location.authorizationStatus) else { return }
            locationFailed = false
            for record in records {
                guard let latitude = record.latitude, let longitude = record.longitude, let timestamp = record.start else { continue }
                if let prior = visits.filter({ $0.sourceName == "CoreLocation significant_change" }).max(by: { ($0.start ?? 0) < ($1.start ?? 0) }),
                   let priorTime = prior.start, let priorLatitude = prior.latitude, let priorLongitude = prior.longitude {
                    let distance = CLLocation(latitude: latitude, longitude: longitude)
                        .distance(from: CLLocation(latitude: priorLatitude, longitude: priorLongitude))
                    if distance < 150 && abs(timestamp - priorTime) < 300 { continue }
                }
                visits.append(record)
            }
            pruneVisits()
            do { try saveVisits() } catch { locationFailed = true }
            onChange?()
            if let newest = visits.last, newest.title == nil {
                await enrichVisit(newest)
            }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clError = error as? CLError, clError.code == .denied {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.location.stopMonitoringVisits()
                self.location.stopMonitoringSignificantLocationChanges()
                self.onChange?()
            }
            return
        }
        // Transient one-shot location errors (network, timeout, locationUnknown) must not
        // permanently disable visit monitoring or lock `authorization(.visits)` to unavailable.
    }
}
