import CoreLocation
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
    private let file: URL
    private var visits: [PhoneSourceSnapshot.Record] = []
    private var enabled = false
    private var locationFailed = false
    private var visitAccessWaiter: CheckedContinuation<Void, Error>?
    enum ReadError: Error { case denied, unavailable, tooManyRecords }

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

    func authorization(_ kind: PhoneSourceKind) -> String {
        if kind == .visits {
            if locationFailed { return "temporarily_unavailable" }
            switch location.authorizationStatus {
            case .authorizedAlways: return "enabled"
            case .authorizedWhenInUse: return "foreground_only"
            default: return "needs_permission"
            }
        }
        return EKEventStore.authorizationStatus(for: kind == .calendar ? .event : .reminder) == .fullAccess ? "enabled" : "needs_permission"
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
        }
    }
    func requestBackgroundVisits() {
        if enabled && location.authorizationStatus == .authorizedWhenInUse { location.requestAlwaysAuthorization() }
    }
    func setVisitsEnabled(_ value: Bool) throws {
        enabled = value
        if enabled { updateMonitoring() }
        else {
            location.stopMonitoringVisits()
            geocoder.cancelGeocode()
            visits = []
            try saveVisits()
        }
    }
    private func updateMonitoring() {
        if enabled && ["enabled", "foreground_only"].contains(authorization(.visits)) { location.startMonitoringVisits() }
        else { location.stopMonitoringVisits() }
    }
    func read(_ kind: PhoneSourceKind, from: Date, to: Date) async throws -> [PhoneSourceSnapshot.Record] {
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
        }
        // Refuse an oversized snapshot rather than silently dropping user data.
        guard values.count <= 2000, values.allSatisfy({ ($0.title?.utf8.count ?? 0) <= 8192 && $0.sourceName.utf8.count <= 1024 }) else {
            throw ReadError.tooManyRecords
        }
        return values.sorted { ($0.start ?? 0, $0.id) < ($1.start ?? 0, $1.id) }
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
    }
    private func enrichVisit(_ record: PhoneSourceSnapshot.Record) async {
        guard enabled, !geocoder.isGeocoding, let latitude = record.latitude, let longitude = record.longitude else { return }
        do {
            let places = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude))
            guard enabled, let index = visits.firstIndex(where: { $0.id == record.id }), let place = places.first else { return }
            let name = [place.locality, place.subLocality, place.name].compactMap { $0 }.joined(separator: " ")
            guard !name.isEmpty else { return }
            visits[index].title = name
            try saveVisits(); onChange?()
        } catch {
            // The visit's coordinates and times remain available when address lookup is offline.
        }
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
            guard let self, enabled, ["enabled", "foreground_only"].contains(authorization(.visits)),
                  latitude.isFinite, longitude.isFinite, accuracy.isFinite, accuracy >= 0,
                  arrival != nil || departure != nil else { return }
            let id = Self.digest("\(latitude):\(longitude):\(arrival ?? departure!)")
            let record = PhoneSourceSnapshot.Record(id: id, sourceName: "CoreLocation visits", start: arrival, end: departure,
                                                    latitude: latitude, longitude: longitude, accuracy: accuracy)
            visits.removeAll { $0.id == id }; visits.append(record); pruneVisits()
            do { try saveVisits() } catch { locationFailed = true }
            onChange?()
            await enrichVisit(record)
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.locationFailed = true; self?.onChange?() }
    }
}
