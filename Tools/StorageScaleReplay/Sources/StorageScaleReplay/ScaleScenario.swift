import Foundation
import MoMoArchive
import MoMoContracts
import MoMoLink
import MoMoRecording

enum ScaleScenario {
    static let framesPerChunk: Int64 = 960_000

    static func perform(phase: String, batch: Int, root: URL) async throws {
        let plan = try WireJSON.decode(ScalePlan.self, from: Data(contentsOf: root.appendingPathComponent("plan.json")))
        var stage = ScaleStage(scenario: root.lastPathComponent, phase: phase, batch: batch, processID: ProcessInfo.processInfo.processIdentifier)
        let start = ContinuousClock.now
        do {
            try requireDisk(root, additionalBytes: phase == "generate" ? Int64(plan.hoursPerBatch * 3600 * 8000) + 64 * 1024 * 1024 : 16 * 1024 * 1024)
            stage.resourceSamples.append(try ResourceSample.read(root: root))
            let watch = try RecordingStore(rootURL: root.appendingPathComponent("watch"))
            let phone = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: plan.receiverDeviceID)
            try await watch.bindReceiver(deviceID: plan.receiverDeviceID, libraryInstanceID: phone.libraryInstanceID)
            let recovery = try await watch.recover()
            try require(recovery.missing.isEmpty && recovery.damaged.isEmpty && recovery.unfinished.isEmpty,
                        "Restart found missing, damaged, or unfinished sealed audio")
            try await phone.recoverInterruptedJobs()
            switch phase {
            case "generate": try await generate(plan: plan, batch: batch, root: root, watch: watch, stage: &stage)
            case "stage-restart": try await stageRestart(root: root, watch: watch, phone: phone, stage: &stage)
            case "drain", "final-drain":
                let limit = phase == "final-drain" ? Int.max : max(2, plan.chunksPerBatch * 2 / 3)
                try await drain(root: root, watch: watch, phone: phone, limit: limit, stage: &stage)
            case "cursor-checkpoint":
                let page = try await phone.recordingsPage(limit: 17)
                try save(PageCheckpoint(sessionIDs: page.items.map(\.sessionID), nextCursor: page.nextCursor),
                         to: root.appendingPathComponent("recordings-cursor.json"))
                stage.checks.append("A real Archive pagination cursor was saved before this worker exits")
            case "verify": try await verify(plan: plan, root: root, watch: watch, phone: phone, stage: &stage)
            default: throw ScaleFailure(description: "Unknown worker phase")
            }
            stage.pendingChunks = try await watch.pendingChunkCount()
            if phase == "drain" {
                let expected = batch * (plan.chunksPerBatch - max(2, plan.chunksPerBatch * 2 / 3))
                try require(stage.pendingChunks == expected, "Per-batch backlog differs from the frozen transfer allowance")
            }
            stage.synthesizedSeconds = Double(stage.generatedChunks * 60)
            stage.newlyAcknowledgedSeconds = Double(stage.acknowledgedChunks * 60)
            stage.pendingSeconds = stage.pendingChunks.map { Double($0 * 60) }
            stage.resourceSamples.append(try ResourceSample.read(root: root))
        } catch {
            stage.failure = String(describing: error)
            stage.synthesizedSeconds = Double(stage.generatedChunks * 60)
            stage.newlyAcknowledgedSeconds = Double(stage.acknowledgedChunks * 60)
            stage.elapsedSeconds = start.duration(to: .now).seconds
            try save(stage, to: stageURL(root, phase: phase, batch: batch))
            throw error
        }
        stage.elapsedSeconds = start.duration(to: .now).seconds
        try save(stage, to: stageURL(root, phase: phase, batch: batch))
        print("\(root.lastPathComponent) \(phase) batch=\(batch) generated=\(stage.generatedChunks) acknowledged=\(stage.acknowledgedChunks) pending=\(stage.pendingChunks.map { String($0) } ?? "unknown") actualSeconds=\(stage.elapsedSeconds)")
    }

    static func stageURL(_ root: URL, phase: String, batch: Int) -> URL {
        root.appendingPathComponent("\(batch)-\(phase).json")
    }

    private static func generate(plan: ScalePlan, batch: Int, root: URL, watch: RecordingStore, stage: inout ScaleStage) async throws {
        for session in plan.sessions where session.batch == batch {
            try requireDisk(root, additionalBytes: 16 * 1024 * 1024)
            let input = root.appendingPathComponent("encoding-\(session.id)")
            let writer = try AACSegmentWriter(directory: input, sessionID: session.id, epochID: session.epochID,
                sourceDeviceID: plan.sourceDeviceID, sourceBuild: "storage-scale-v1", sourceKind: .fixture,
                inputSampleRate: 16_000, wallClockAnchor: session.anchor, timezoneOffset: 28_800)
            try await watch.beginEpoch(sessionID: session.id, epochID: session.epochID, sourceDeviceID: plan.sourceDeviceID)
            var generated: Int64 = 0
            var random = UInt64(session.index + 1) &* 0x9E3779B97F4A7C15
            let expected = Int64(session.chunkCount) * framesPerChunk
            while generated < expected {
                let count = Int(min(8192, expected - generated))
                var samples = [Float](repeating: 0, count: count)
                // Deterministic, low-amplitude, non-speech input. Every encoded frame is generated here.
                for index in samples.indices {
                    random ^= random << 13; random ^= random >> 7; random ^= random << 17
                    samples[index] = Float(Int32(truncatingIfNeeded: random >> 32)) / Float(Int32.max) * 0.03
                }
                for chunk in try writer.append(samples) {
                    try await preserve(chunk, root: root, watch: watch, stage: &stage)
                }
                generated += Int64(count)
            }
            for chunk in try writer.finish() { try await preserve(chunk, root: root, watch: watch, stage: &stage) }
            try require(writer.totalFrames == expected, "Native AAC encoding lost source frames")
            try require(try await watch.sealedEndFrame(sessionID: session.id, epochID: session.epochID) == expected, "Watch ledger does not cover the encoded epoch")
            try await watch.recordMark(CaptureMark(sessionID: session.id, epochID: session.epochID,
                sourceDeviceID: plan.sourceDeviceID, sourceFrame: expected / 2))
            try await watch.recordEpochEnded(CaptureEpochEnded(sessionID: session.id, epochID: session.epochID,
                sourceDeviceID: plan.sourceDeviceID, endFrame: expected, reason: .stopped))
            // The production ledger now owns independently verified copies of every original.
            try FileManager.default.removeItem(at: input)
            stage.resourceSamples.append(try ResourceSample.read(root: root))
            print("encoded session=\(session.index) batch=\(batch) syntheticMinutes=\(session.chunkCount)")
        }
        try require(stage.generatedChunks == plan.chunksPerBatch, "Generated batch count differs from the independent plan")
        stage.checks.append("All planned source frames were really encoded into 60-second AAC files and sealed")
    }

    private static func preserve(_ chunk: EncodedChunk, root: URL, watch: RecordingStore, stage: inout ScaleStage) async throws {
        let manifest = chunk.envelope.manifest
        try require(manifest.sourceKind == .fixture && manifest.codec == .aac && manifest.frames.count == framesPerChunk,
                    "Unexpected encoding format or segment duration")
        _ = try await watch.sealChunk(audioAt: chunk.audioURL, envelope: chunk.envelope)
        try append(ScaleInput(chunkID: manifest.chunkID, sessionID: manifest.sessionID, epochID: manifest.epochID,
            sequence: manifest.sequence, frames: manifest.frames, audioSHA256: manifest.audioSHA256,
            manifestSHA256: chunk.envelope.manifestSHA256, byteCount: manifest.byteCount), to: root.appendingPathComponent("inputs.jsonl"))
        stage.generatedChunks += 1
    }

    private static func stageRestart(root: URL, watch: RecordingStore, phone: ArchiveStore, stage: inout ScaleStage) async throws {
        try await controls(kind: .capture, watch: watch, phone: phone, stage: &stage)
        let chunks = try await watch.pendingChunks(limit: 2)
        try require(chunks.count == 2, "Restart scenario needs two unacknowledged chunks")
        for (index, chunk) in chunks.enumerated() {
            let item = try transfer(chunk, root: root, phone: phone, stage: &stage)
            if index == 0 {
                guard case .accepted = try await phone.commitReceivedChunk(item) else { throw ScaleFailure(description: "Restart checkpoint was not a first acceptance") }
                stage.acceptedChunks += 1
            }
        }
        try require(try await watch.cleanupAcknowledgedChunks().isEmpty, "Unacknowledged originals were removed")
        stage.checks.append("Worker exits with one persisted receive lacking ReceiptApplied and one preserved inbox file")
    }

    private static func drain(root: URL, watch: RecordingStore, phone: ArchiveStore, limit: Int, stage: inout ScaleStage) async throws {
        let before = try await watch.pendingChunkCount()
        for result in try await phone.processInbox() {
            guard case .accepted = try result.result.get() else { throw ScaleFailure(description: "Preserved inbox did not recover exactly once") }
            stage.acceptedChunks += 1
        }
        for receipt in try await phone.pendingReceipts() {
            _ = try await watch.applyReceipt(receipt)
            try await phone.markReceiptSent(receiptID: receipt.receiptID)
        }
        _ = try await watch.cleanupAcknowledgedChunks()
        var done = before - (try await watch.pendingChunkCount())
        stage.acknowledgedChunks = done
        var submission = LinkSubmissionState()
        submission.update(activation: .activated, isReachable: false)
        while done < limit {
            let candidates = try await watch.pendingChunks(limit: min(5, limit - done))
            guard !candidates.isEmpty else { break }
            let group = Array(candidates.prefix(4))
            for chunk in group { try require(try submission.shouldSubmit(chunk.envelope), "Available transfer slot was rejected") }
            if candidates.count == 5 { try require(try !submission.shouldSubmit(candidates[4].envelope), "A fifth outstanding transfer exceeded the file budget") }
            stage.maximumReservedFiles = max(stage.maximumReservedFiles, group.count)
            // Reverse each bounded group so receipt order differs from capture order.
            for chunk in group.reversed() {
                let began = ContinuousClock.now
                let item = try transfer(chunk, root: root, phone: phone, stage: &stage)
                guard case .accepted(let receipt) = try await phone.commitReceivedChunk(item) else { throw ScaleFailure(description: "Unexpected first receive result") }
                try require(receipt.matches(chunk.envelope), "Receipt acknowledges different content")
                stage.acceptedChunks += 1
                stage.receiveCommitMilliseconds.append(began.duration(to: .now).seconds * 1000)
                if done % 37 == 0 {
                    guard case .duplicate(let repeated) = try await phone.commitReceivedChunk(transfer(chunk, root: root, phone: phone, stage: &stage)) else {
                        throw ScaleFailure(description: "Duplicate receive created a new logical item")
                    }
                    try require(repeated == receipt, "Duplicate receive changed its durable receipt")
                    stage.duplicateReceives += 1
                }
                let applied = try await watch.applyReceipt(receipt)
                try require(try await watch.applyReceipt(receipt) == applied, "Receipt retry created a second logical application")
                try await phone.markReceiptSent(receiptID: receipt.receiptID)
                submission.didFinish(chunkID: chunk.envelope.manifest.chunkID)
                done += 1
                stage.acknowledgedChunks = done
            }
            _ = try await watch.cleanupAcknowledgedChunks()
        }
        stage.acknowledgedChunks = done
        try await controls(kind: .capture, watch: watch, phone: phone, stage: &stage)
        try await controls(kind: .receipt, watch: watch, phone: phone, stage: &stage)
        stage.checks.append("Restarted inbox and receipts converge; reverse-order delivery and duplicates preserve content and identity")
    }

    private static func transfer(_ chunk: RecordedChunk, root: URL, phone: ArchiveStore, stage: inout ScaleStage) throws -> InboxItem {
        let url = root.appendingPathComponent("transport-\(UUID()).m4a")
        try FileManager.default.copyItem(at: chunk.audioURL, to: url)
        let item = try phone.inbox.preserve(fileURL: url, envelope: chunk.envelope)
        try require(!FileManager.default.fileExists(atPath: url.path), "Inbox did not take synchronous ownership")
        stage.transferredBytes += chunk.envelope.manifest.byteCount
        return item
    }

    @discardableResult private static func controls(kind: RecordingControlKind, watch: RecordingStore, phone: ArchiveStore, stage: inout ScaleStage) async throws -> Set<UUID> {
        var cursor: Int64 = 0
        var appliedChunks: Set<UUID> = []
        while true {
            let entries = try await watch.controlBatch(kind: kind, after: cursor)
            if entries.isEmpty { break }
            var budget = LinkControlBudget()
            var last = cursor
            for entry in entries {
                if try !budget.include(entry.message) { break }
                switch entry.message {
                case .captureMark(let mark): try await phone.receiveMark(mark)
                case .epochEnded(let end): try await phone.receiveEpochEnd(end)
                case .receiptApplied(let applied):
                    try require(appliedChunks.insert(applied.receipt.chunkID).inserted, "Receipt control pagination repeated a chunk")
                    try await phone.applyReceipt(applied)
                default: throw ScaleFailure(description: "Unexpected retained control message")
                }
                last = entry.sequence
                stage.controlMessages += 1
            }
            try require(last > cursor && budget.count <= 32 && budget.bytes <= 16 * 1024, "Control pagination stalled or exceeded its budget")
            stage.controlPages += 1
            stage.maximumControlPageBytes = max(stage.maximumControlPageBytes, budget.bytes)
            cursor = last
        }
        return appliedChunks
    }

    private static func verify(plan: ScalePlan, root: URL, watch: RecordingStore, phone: ArchiveStore, stage: inout ScaleStage) async throws {
        let ledger = try inputLedger(root)
        try require(ledger.count == plan.chunksPerBatch * plan.batches, "Input count differs from the frozen plan")
        try require(Set(ledger.map(\.chunkID)).count == ledger.count, "Input ledger repeats a chunk ID")
        try require(Set(ledger.map(\.audioSHA256)).count == ledger.count, "Synthetic AAC inputs are not independently distinct")
        try require(try await watch.pendingChunkCount() == 0, "Final Watch queue is not empty")
        try require(try phone.inbox.pendingItems().isEmpty, "Final phone inbox is not empty")
        try await controls(kind: .capture, watch: watch, phone: phone, stage: &stage)
        let appliedChunks = try await controls(kind: .receipt, watch: watch, phone: phone, stage: &stage)
        try require(appliedChunks == Set(ledger.map(\.chunkID)), "ReceiptApplied controls omit or add an immutable input chunk")
        let checkpoint = try WireJSON.decode(PageCheckpoint.self, from: Data(contentsOf: root.appendingPathComponent("recordings-cursor.json")))
        var cursor = checkpoint.nextCursor, sessionIDs = checkpoint.sessionIDs
        while let next = cursor {
            let page = try await phone.recordingsPage(limit: 17, cursor: next)
            sessionIDs += page.items.map(\.sessionID); cursor = page.nextCursor
        }
        try require(Set(sessionIDs) == Set(plan.sessions.map(\.id)), "Archive pages omit or duplicate planned sessions")
        try require(sessionIDs.count == plan.sessions.count, "Archive cursor returned duplicate sessions")
        for session in plan.sessions {
            let inputs = ledger.filter { $0.sessionID == session.id }.sorted { $0.sequence < $1.sequence }
            try require(inputs.count == session.chunkCount, "Wrong session chunk count")
            for (sequence, item) in inputs.enumerated() {
                try require(item.epochID == session.epochID && item.sequence == Int64(sequence)
                    && item.frames.start == Int64(sequence) * framesPerChunk && item.frames.count == framesPerChunk,
                    "Chunk frame position differs from the independent session plan")
                guard let stored = try await watch.chunk(id: item.chunkID) else { throw ScaleFailure(description: "Watch lost its acknowledged ledger entry") }
                try require(stored.state == .removed && stored.envelope.manifestSHA256 == item.manifestSHA256,
                            "Watch cleanup lost immutable identity or state")
                let lease = try await phone.acquireAudioLease(chunkID: item.chunkID)
                do {
                    try require(lease.manifest.audioSHA256 == item.audioSHA256 && lease.manifest.frames == item.frames,
                                "Received original differs from its input ledger")
                    await phone.releaseAudioLease(id: lease.id)
                } catch { await phone.releaseAudioLease(id: lease.id); throw error }
            }
            let coverage = try await phone.recordingCoverage(sessionID: session.id, configurationFingerprint: nil)
            try require(coverage.receivedDuration == Double(session.chunkCount * 60), "Received frame union has incorrect duration")
            try require(coverage.epochs.count == 1 && coverage.epochs[0].notReceived.isEmpty
                && coverage.epochs[0].unknownTailFromFrame == nil && coverage.epochs[0].marks.count == 1,
                "Epoch closure, capture mark, or receipt coverage did not survive replay")
            try require(coverage.processedDuration == nil && coverage.watchCapturedDuration == nil,
                        "Unexecuted ASR or Watch status was reported as measured")
            stage.verifiedSessions += 1
        }
        stage.checks.append("Independent input ledger, retained receipts, frame unions, marks, originals and paginated sessions match after a fresh process restart")
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
