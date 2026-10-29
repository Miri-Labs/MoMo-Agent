import Foundation
import Testing
import MoMoLink

struct SelectedWatchContextTests {
    @Test func switchingAndInactiveCallbacksKeepTheirOriginalSelectionAndOrder() {
        let clock = SelectedWatchEventClock()
        let a = URL(fileURLWithPath: "/selected-watch-a", isDirectory: true)
        let b = URL(fileURLWithPath: "/selected-watch-b", isDirectory: true)
        let selectedA = clock.select(activation: .activated, peerState: .available, directoryURL: a)
        let delayedA = clock.receive()
        let inactive = clock.select(activation: .inactive, peerState: .available, directoryURL: a)
        let drainingA = clock.receive()
        let selectedB = clock.select(activation: .activated, peerState: .available, directoryURL: b)
        let currentB = clock.receive()

        #expect(delayedA.epoch == selectedA.epoch && delayedA.directoryURL == a)
        #expect(delayedA.isAvailable)
        #expect(drainingA.epoch == inactive.epoch && drainingA.directoryURL == nil)
        #expect(!drainingA.isAvailable)
        #expect(currentB.epoch == selectedB.epoch && currentB.directoryURL == b)
        #expect(currentB.epoch != delayedA.epoch)
        let stamps = [selectedA, delayedA, inactive, drainingA, selectedB, currentB]
        #expect(stamps.map(\.sequence) == [1, 2, 3, 4, 5, 6])
        // A later consumer cannot relabel the captured A callback using the now-current B directory.
        #expect(delayedA.directoryURL == a)
    }

    @Test func reactivationCreatesANewEpochButReachableRefreshDoesNotRefreshCachedStatus() {
        let clock = SelectedWatchEventClock()
        let directory = URL(fileURLWithPath: "/selected-watch", isDirectory: true)
        let first = clock.select(activation: .activated, peerState: .available, directoryURL: directory)
        let repeated = clock.select(activation: .activated, peerState: .available, directoryURL: directory)
        #expect(first.epoch == repeated.epoch)
        #expect(first.sequence < repeated.sequence)
        let removed = clock.select(activation: .activated, peerState: .companionNotInstalled, directoryURL: directory)
        #expect(!removed.isAvailable && removed.directoryURL == nil)
        let reinstalled = clock.select(activation: .activated, peerState: .available, directoryURL: directory)
        #expect(reinstalled.epoch != first.epoch)
        let unpaired = clock.select(activation: .activated, peerState: .notPaired, directoryURL: directory)
        #expect(!unpaired.isAvailable && unpaired.directoryURL == nil)
        let unknown = clock.select(activation: .activated, peerState: .available, directoryURL: nil)
        #expect(!unknown.isAvailable)
    }
}
