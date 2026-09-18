import Foundation
import Testing
@testable import FanHelper

struct LeaseOwnershipTests {
    @Test func committedLeaseYieldsWhenAnotherControllerSelectsOriginalTarget() {
        let journal = LeaseJournal(
            leaseID: UUID(), fanID: 0, targetRPM: 1200,
            originalTargetRPM: 1000, phase: .active
        )
        #expect(journal.recoveryAction(mode: 1, targetRPM: 1200) == .restoreAutomatic)
        #expect(journal.recoveryAction(mode: 1, targetRPM: 1000) == .releaseExternal)
    }

    @Test func interruptedModeTransitionRecognizesBothSidesOfTargetWrite() {
        let journal = LeaseJournal(
            leaseID: UUID(), fanID: 0, targetRPM: 1200,
            originalTargetRPM: 1000, phase: .prepared
        )
        #expect(journal.recoveryAction(mode: 1, targetRPM: 1000) == .restoreAutomatic)
        #expect(journal.recoveryAction(mode: 1, targetRPM: 1200) == .restoreAutomatic)
        #expect(journal.recoveryAction(mode: 1, targetRPM: 1800) == .releaseExternal)
    }

    @Test func interruptedRestorationOnlyOwnsItsCapturedTarget() {
        let journal = LeaseJournal(
            leaseID: UUID(), fanID: 0, targetRPM: 1200,
            originalTargetRPM: 1000, phase: .restoring,
            restorationTargetRPM: 1000
        )
        #expect(journal.recoveryAction(mode: 1, targetRPM: 1000) == .restoreAutomatic)
        #expect(journal.recoveryAction(mode: 1, targetRPM: 1200) == .releaseExternal)
    }

    @Test func pendingModeWriteRequiresRollbackDespiteAutomaticReadback() {
        let pending = LeaseJournal(
            leaseID: UUID(), fanID: 0, targetRPM: 1200,
            originalTargetRPM: 1000, phase: .prepared
        )
        #expect(pending.recoveryAction(mode: 0, targetRPM: 1000) == .restoreAutomatic)
        let committed = LeaseJournal(
            leaseID: pending.leaseID, fanID: 0, targetRPM: 1200,
            originalTargetRPM: 1000, phase: .active
        )
        #expect(committed.recoveryAction(mode: 0, targetRPM: 1000) == .releaseAutomatic)
        #expect(committed.recoveryAction(mode: 1, targetRPM: nil) == .hold)
    }

    @Test func productionEngineControlsTwoFansAndReleasesOnlySelectedFan() throws {
        let fixture = EngineFixture()
        try fixture.take(fanID: 0, rpm: 1_200)
        try fixture.take(fanID: 1, rpm: 1_700)

        #expect(fixture.targets == [0: 1_200, 1: 1_700])
        #expect(fixture.hardware.states[0] == FakeControlState(mode: 1, targetRPM: 1_200))
        #expect(fixture.hardware.states[1] == FakeControlState(mode: 1, targetRPM: 1_700))

        let restored = FanLeaseEngine.release(
            fanID: 0, leases: &fixture.leases, journals: &fixture.journals,
            hardware: fixture.hardwareAdapter, persist: fixture.persist,
            removeJournal: fixture.remove
        )

        #expect(restored)
        #expect(fixture.targets == [1: 1_700])
        #expect(fixture.hardware.states[0]?.mode == 0)
        #expect(fixture.hardware.states[1] == FakeControlState(mode: 1, targetRPM: 1_700))
        #expect(Set(fixture.durableEvidence.keys) == [1])
    }

    @Test func productionExpiryTriggerReleasesAllOwnedFans() throws {
        let fixture = EngineFixture(expiry: ContinuousClock().now.advanced(by: .seconds(-1)))
        try fixture.take(fanID: 0, rpm: 1_200)
        try fixture.take(fanID: 1, rpm: 1_700)

        let result = FanLeaseEngine.releaseExpired(
            at: ContinuousClock().now, leases: &fixture.leases, journals: &fixture.journals,
            hardware: fixture.hardwareAdapter, persist: fixture.persist,
            removeJournal: fixture.remove
        )

        #expect(result == true)
        #expect(fixture.targets.isEmpty)
        #expect(fixture.durableEvidence.isEmpty)
        #expect(fixture.hardware.states.values.allSatisfy { $0.mode == 0 })
    }

    @Test func productionConnectionEndTriggerReleasesWholeSession() throws {
        let fixture = EngineFixture()
        try fixture.take(fanID: 0, rpm: 1_200)
        try fixture.take(fanID: 1, rpm: 1_700)

        let result = FanLeaseEngine.releaseConnection(
            ownerID: fixture.ownerID, leases: &fixture.leases, journals: &fixture.journals,
            hardware: fixture.hardwareAdapter, persist: fixture.persist,
            removeJournal: fixture.remove
        )

        #expect(result == true)
        #expect(fixture.targets.isEmpty)
        #expect(fixture.durableEvidence.isEmpty)
        #expect(fixture.hardware.states.values.allSatisfy { $0.mode == 0 })
    }

    @Test func productionRestoreFailureRetainsEvidenceAndAllPotentialTargets() throws {
        let fixture = EngineFixture()
        try fixture.take(fanID: 0, rpm: 1_200)
        try fixture.take(fanID: 1, rpm: 1_700)
        fixture.hardware.failingRestoreFanIDs.insert(0)

        let restored = FanLeaseEngine.release(
            fanID: 0, leases: &fixture.leases, journals: &fixture.journals,
            hardware: fixture.hardwareAdapter, persist: fixture.persist,
            removeJournal: fixture.remove
        )

        #expect(!restored)
        #expect(fixture.targets == [0: 1_200, 1: 1_700])
        #expect(fixture.journals[0]?.phase == .restoring)
        #expect(fixture.durableEvidence[0]?.phase == .restoring)
        #expect(fixture.hardware.states[1] == FakeControlState(mode: 1, targetRPM: 1_700))
    }
}

private struct FakeControlState: Equatable {
    var mode: Int64
    var targetRPM: Double?
}

private struct FakeHardwareError: Error {}

private final class FakeFanHardware {
    var states: [Int: FakeControlState] = [:]
    var failingRestoreFanIDs: Set<Int> = []

    func setManual(fanID: Int, rpm: Int) {
        states[fanID] = FakeControlState(mode: 1, targetRPM: Double(rpm))
    }

    func controlState(fanID: Int) throws -> (mode: Int64, targetRPM: Double?) {
        guard let state = states[fanID] else { throw FakeHardwareError() }
        return (state.mode, state.targetRPM)
    }

    func restoreAutomatic(fanID: Int) throws {
        guard !failingRestoreFanIDs.contains(fanID), let state = states[fanID] else {
            throw FakeHardwareError()
        }
        states[fanID] = FakeControlState(mode: 0, targetRPM: state.targetRPM)
    }
}

private final class EngineFixture {
    let hardware = FakeFanHardware()
    let owner = NSObject()
    let sessionID = UUID()
    var expiry: ContinuousClock.Instant
    var leases: [Int: Lease] = [:]
    var journals: [Int: LeaseJournal] = [:]
    var durableEvidence: [Int: LeaseJournal] = [:]

    init(expiry: ContinuousClock.Instant = ContinuousClock().now.advanced(by: .seconds(30))) {
        self.expiry = expiry
    }

    var ownerID: ObjectIdentifier { ObjectIdentifier(owner) }
    var targets: [Int: Int] {
        Dictionary(uniqueKeysWithValues: leases.values.map { ($0.fanID, $0.targetRPM) })
    }
    var hardwareAdapter: LeaseHardware {
        LeaseHardware(
            setManual: hardware.setManual,
            controlState: hardware.controlState,
            restoreAutomatic: hardware.restoreAutomatic
        )
    }
    var persist: (LeaseJournal) throws -> Void {
        { [unowned self] in durableEvidence[$0.fanID] = $0 }
    }
    var remove: (Int) -> Void {
        { [unowned self] in durableEvidence.removeValue(forKey: $0) }
    }

    func take(fanID: Int, rpm: Int) throws {
        let lease = Lease(
            id: sessionID, fanID: fanID, targetRPM: rpm, originalTargetRPM: 1_000,
            uid: 501, ownerID: ownerID, expiresAt: expiry
        )
        try FanLeaseEngine.take(
            lease, leases: &leases, journals: &journals, hardware: hardwareAdapter,
            persist: persist, removeJournal: remove, canContinue: { true }
        )
    }
}
