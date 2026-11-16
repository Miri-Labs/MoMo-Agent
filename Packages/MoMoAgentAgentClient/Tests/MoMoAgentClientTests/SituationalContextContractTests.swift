import Foundation
import XCTest
@testable import MoMoAgentClient

final class SituationalContextContractTests: XCTestCase, @unchecked Sendable {
    private actor CaptureTransport: AgentTransport {
        let status: Int
        let responseJSON: String
        private(set) var lastRequest: URLRequest?

        init(status: Int = 200, responseJSON: String) {
            self.status = status
            self.responseJSON = responseJSON
        }

        func open(_ request: URLRequest) async throws -> AgentByteStream? {
            lastRequest = request
            let data = Data(responseJSON.utf8)
            return AgentByteStream(status: status, contentType: "application/json", chunks: AsyncThrowingStream { continuation in
                continuation.yield(data)
                continuation.finish()
            })
        }
    }

    private func makeClient(transport: any AgentTransport) throws -> AgentClient {
        try AgentClient(
            baseURL: URL(string: "http://127.0.0.1:8765")!,
            credential: "test-secret",
            assistantID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            configuration: .ephemeral,
            transport: transport
        )
    }

    func testDeviceTelemetrySnapshotSnakeCaseWireSyncAndReceiptValidation() async throws {
        let phoneID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let watchID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let snapshot = DeviceTelemetrySnapshot(
            device: phoneID,
            revision: 7,
            state: "enabled",
            observedAt: Date(timeIntervalSince1970: 1_700_000_120),
            timezone: "Asia/Shanghai",
            phone: .init(
                batteryLevel: 0.24,
                batteryState: "unplugged",
                lowPowerMode: true,
                thermalState: 1,
                freeStorageBytes: 12_345_678_900,
                audioRoute: .init(portType: "BluetoothA2DPOutput", portName: "AirPods Pro")
            ),
            watch: .init(
                deviceId: watchID.uuidString.lowercased(),
                sampledAt: 1_700_000_115,
                activity: "recording",
                pendingChunkCount: 3,
                pendingBytes: 24_576,
                batteryLevel: 0.16,
                batteryState: "unplugged",
                lowPowerMode: false,
                thermalState: 0,
                freeStorageBytes: 2_147_483_648
            )
        )

        let transport = CaptureTransport(responseJSON: #"{"device_id":"11111111-2222-3333-4444-555555555555","revision":7}"#)
        let client = try makeClient(transport: transport)
        try await client.syncDeviceTelemetry(snapshot)

        let sent = await transport.lastRequest
        XCTAssertEqual(sent?.httpMethod, "POST")
        XCTAssertEqual(sent?.url?.path, "/v1/device-telemetry")
        let bodyData = try XCTUnwrap(sent?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(json["device_id"] as? String, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(json["revision"] as? Int64, 7)
        XCTAssertEqual(json["state"] as? String, "enabled")
        XCTAssertEqual(json["observed_at"] as? Double, 1_700_000_120)
        XCTAssertEqual(json["timezone"] as? String, "Asia/Shanghai")

        let phone = try XCTUnwrap(json["phone"] as? [String: Any])
        XCTAssertEqual(phone["battery_level"] as? Double, 0.24)
        XCTAssertEqual(phone["battery_state"] as? String, "unplugged")
        XCTAssertEqual(phone["low_power_mode"] as? Bool, true)
        XCTAssertEqual(phone["thermal_state"] as? Int, 1)
        XCTAssertEqual(phone["free_storage_bytes"] as? Int64, 12_345_678_900)
        let route = try XCTUnwrap(phone["audio_route"] as? [String: Any])
        XCTAssertEqual(route["port_type"] as? String, "BluetoothA2DPOutput")
        XCTAssertEqual(route["port_name"] as? String, "AirPods Pro")

        let watch = try XCTUnwrap(json["watch"] as? [String: Any])
        XCTAssertEqual(watch["device_id"] as? String, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertEqual(watch["sampled_at"] as? Double, 1_700_000_115)
        XCTAssertEqual(watch["activity"] as? String, "recording")
        XCTAssertEqual(watch["pending_chunk_count"] as? Int, 3)
        XCTAssertEqual(watch["pending_bytes"] as? Int64, 24_576)
        XCTAssertEqual(watch["battery_level"] as? Double, 0.16)
        XCTAssertEqual(watch["battery_state"] as? String, "unplugged")

        let mismatched = CaptureTransport(responseJSON: #"{"device_id":"11111111-2222-3333-4444-555555555555","revision":6}"#)
        do {
            try await makeClient(transport: mismatched).syncDeviceTelemetry(snapshot)
            XCTFail("Expected mismatched receipt revision error")
        } catch AgentClientError.invalidResponse { }
    }

    func testPhoneSourceKindIncludesMotionAndSyncsOverWire() async throws {
        XCTAssertEqual(PhoneSourceKind.allCases, [.visits, .calendar, .reminders, .motion])
        let device = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let now = Date(timeIntervalSince1970: 1_700_086_400)
        let snapshot = PhoneSourceSnapshot(
            device: device,
            kind: .motion,
            revision: 4,
            state: "enabled",
            observedAt: now,
            windowStart: now.addingTimeInterval(-86400),
            windowEnd: now,
            records: [
                .init(
                    id: "motion-1700080000-automotive",
                    title: "automotive",
                    sourceName: "CoreMotion confidence:high",
                    start: 1_700_080_000,
                    end: 1_700_081_800
                )
            ]
        )

        let transport = CaptureTransport(
            responseJSON: #"{"device_id":"22222222-3333-4444-5555-666666666666","kind":"motion","revision":4}"#
        )
        try await makeClient(transport: transport).syncPhoneSource(snapshot)
        let sent = await transport.lastRequest
        XCTAssertEqual(sent?.url?.path, "/v1/phone-sources")
        let body = try XCTUnwrap(sent?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "motion")
        let records = try XCTUnwrap(json["records"] as? [[String: Any]])
        XCTAssertEqual(records.first?["id"] as? String, "motion-1700080000-automotive")
        XCTAssertEqual(records.first?["title"] as? String, "automotive")
        XCTAssertEqual(records.first?["source_name"] as? String, "CoreMotion confidence:high")
    }

    func testHealthSnapshotV2EncodingAndV1BackwardCompatibility() async throws {
        let v1WireJSON = """
        {
          "device_id": "33333333-4444-5555-6666-777777777777",
          "revision": 2,
          "state": "enabled",
          "observed_at": 1700000000,
          "window_start": 1699481600,
          "window_end": 1700000000,
          "timezone": "Asia/Shanghai",
          "observations": [
            {
              "metric": "steps",
              "unit": "count",
              "value": 8420,
              "start": 1699913600,
              "end": 1700000000,
              "source_name": "Apple Health",
              "source_bundle": "com.apple.Health"
            }
          ]
        }
        """
        let snakeDecoder = JSONDecoder()
        snakeDecoder.keyDecodingStrategy = .convertFromSnakeCase
        let decodedV1 = try snakeDecoder.decode(HealthSnapshot.self, from: Data(v1WireJSON.utf8))
        XCTAssertEqual(decodedV1.observations.count, 1)
        XCTAssertEqual(decodedV1.sleepSessions, [])
        XCTAssertEqual(decodedV1.workouts, [])
        XCTAssertEqual(decodedV1.activitySummaries, [])

        let v1LocalJSON = """
        {
          "deviceId": "33333333-4444-5555-6666-777777777777",
          "revision": 2,
          "state": "enabled",
          "observedAt": 1700000000,
          "windowStart": 1699481600,
          "windowEnd": 1700000000,
          "timezone": "Asia/Shanghai",
          "observations": []
        }
        """
        let decodedLocalV1 = try JSONDecoder().decode(HealthSnapshot.self, from: Data(v1LocalJSON.utf8))
        XCTAssertEqual(decodedLocalV1.sleepSessions, [])
        XCTAssertEqual(decodedLocalV1.workouts, [])
        XCTAssertEqual(decodedLocalV1.activitySummaries, [])

        let device = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let v2 = HealthSnapshot(
            device: device,
            revision: 9,
            state: "enabled",
            observedAt: now,
            windowStart: now.addingTimeInterval(-6 * 86400),
            timezone: "Asia/Shanghai",
            observations: [
                .init(metric: "hrv_sdnn", unit: "ms", value: 48.5, start: now.addingTimeInterval(-600), end: now.addingTimeInterval(-600),
                      sourceName: "Apple Watch", sourceBundle: "com.apple.health")
            ],
            sleepSessions: [
                .init(id: "sleep-1699974000-1700001000", start: 1_699_974_000, end: 1_700_001_000,
                      asleepSeconds: 25_200, inBedSeconds: 27_000, deepSeconds: 4_200, coreSeconds: 15_600,
                      remSeconds: 5_400, awakeSeconds: 1_800, sourceName: "Apple Watch", sourceBundle: "com.apple.health")
            ],
            workouts: [
                .init(id: "workout-1", activityType: "climbing", start: 1_699_950_000, end: 1_699_955_400,
                      durationSeconds: 5_400, activeEnergyKcal: 512.4, distanceMeters: nil,
                      sourceName: "Apple Watch", sourceBundle: "com.apple.health")
            ],
            activitySummaries: [
                .init(date: "2023-11-14", activeEnergyKcal: 620, activeEnergyGoalKcal: 600,
                      exerciseMinutes: 52, exerciseGoalMinutes: 30, standHours: 13, standGoalHours: 12)
            ]
        )

        let transport = CaptureTransport(responseJSON: #"{"device_id":"33333333-4444-5555-6666-777777777777","revision":9}"#)
        try await makeClient(transport: transport).syncHealth(v2)
        let sent = await transport.lastRequest
        let body = try XCTUnwrap(sent?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sleep = try XCTUnwrap((json["sleep_sessions"] as? [[String: Any]])?.first)
        XCTAssertEqual(sleep["asleep_seconds"] as? Double, 25_200)
        XCTAssertEqual(sleep["in_bed_seconds"] as? Double, 27_000)
        XCTAssertEqual(sleep["deep_seconds"] as? Double, 4_200)
        XCTAssertEqual(sleep["core_seconds"] as? Double, 15_600)
        XCTAssertEqual(sleep["rem_seconds"] as? Double, 5_400)
        XCTAssertEqual(sleep["awake_seconds"] as? Double, 1_800)

        let workout = try XCTUnwrap((json["workouts"] as? [[String: Any]])?.first)
        XCTAssertEqual(workout["activity_type"] as? String, "climbing")
        XCTAssertEqual(workout["duration_seconds"] as? Double, 5_400)
        XCTAssertEqual(workout["active_energy_kcal"] as? Double, 512.4)

        let ring = try XCTUnwrap((json["activity_summaries"] as? [[String: Any]])?.first)
        XCTAssertEqual(ring["date"] as? String, "2023-11-14")
        XCTAssertEqual(ring["active_energy_goal_kcal"] as? Double, 600)
        XCTAssertEqual(ring["exercise_goal_minutes"] as? Double, 30)
        XCTAssertEqual(ring["stand_goal_hours"] as? Double, 12)

        let roundTripped = try snakeDecoder.decode(HealthSnapshot.self, from: body)
        XCTAssertEqual(roundTripped, v2)
    }
}
