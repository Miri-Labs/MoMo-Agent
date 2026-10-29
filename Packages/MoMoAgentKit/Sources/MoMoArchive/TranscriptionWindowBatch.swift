import Foundation
import MoMoContracts

extension ArchiveStore {
    /// Expand one scheduler-selected window only within its leased received snapshot.
    /// Never wait for another transfer, cross an epoch, or bypass a reserved user batch.
    public func claimCompanionWindows(after first: TranscriptionWindowTicket,
                                      inputLease: TranscriptionInputLease,
                                      maximumCount: Int) throws -> [TranscriptionWindowTicket] {
        try validateWindowTicket(first)
        guard (1...4).contains(maximumCount), inputLease.contains(first) else { throw ArchiveError.staleAttempt }
        guard maximumCount > 1 else { return [] }
        let window = first.window
        let rows = try database.rows("""
            SELECT id,descriptor FROM analysis_windows
            WHERE epoch_id=? AND generation=? AND configuration_hash=? AND state='pending'
              AND json_extract(CAST(descriptor AS TEXT),'$.analysisAnchor')=?
              AND json_extract(CAST(descriptor AS TEXT),'$.modelCoreFrames.start')>=?
            ORDER BY json_extract(CAST(descriptor AS TEXT),'$.modelCoreFrames.start')
            LIMIT ?
            """, [.text(window.epochID.uuidString), .integer(first.expectedGeneration),
                  .text(window.configurationFingerprint), .integer(window.analysisAnchor),
                  .integer(window.modelCoreFrames.end), .integer(Int64(maximumCount - 1))])
        var claimed: [TranscriptionWindowTicket] = []
        do {
            for row in rows {
                let next = try WireJSON.decode(ArchiveAnalysisWindow.self, from: row.requireData(1))
                guard next.contextFrames.end <= (inputLease.inputs.last?.envelope.manifest.frames.end ?? 0),
                      let ticket = try claimTranscriptionWindow(configurationFingerprint: window.configurationFingerprint,
                        batchExecution: first.batchExecution, inputLease: inputLease, sessionID: window.sessionID,
                        expectedGeneration: first.expectedGeneration, selectedWindowID: row.requireString(0)) else { break }
                claimed.append(ticket)
            }
            return claimed
        } catch {
            for ticket in claimed { try cancelTranscriptionWindow(ticket: ticket) }
            throw error
        }
    }
}
