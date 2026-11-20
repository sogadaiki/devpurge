import Foundation

@main
struct BackupMonitorTests {
    static func main() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ seconds: Int) -> Date { start.addingTimeInterval(TimeInterval(seconds)) }
        func status(_ raw: String?, running: Bool? = true, id: String? = "ext",
                    session: Date? = nil) -> BackupStatusSample {
            BackupStatusSample(running: running, phase: raw, destinationID: id,
                               destinationName: id, sessionStart: session)
        }
        func saved(_ seconds: Int, id: String = "ext") -> BackupSaveEvidence {
            BackupSaveEvidence(destinationID: id, destinationName: id, completedAt: at(seconds),
                               snapshotDate: at(seconds - 8))
        }
        let idle = status(nil, running: false, id: nil)
        let unknown = status(nil, running: nil, id: nil)
        let copying = status("Copying", session: start)
        precondition(BackupPhase(idle) == .idle && BackupPhase(unknown) == .unknown)
        precondition(BackupPhase(status("FindingChanges")) == .preparing)
        precondition(BackupPhase(copying) == .copying)
        precondition(BackupPhase(status("ThinningPostBackup")) == .finishing)
        precondition(BackupPhase(status("Stopping")) == .stopping)
        precondition(BackupPhase(status("NewPhase")) == .running)

        var values = BackupTracking()
        values.observe(copying, at: at(5), freeBytes: 100)
        values.observe(copying, at: at(15), freeBytes: 80)
        values.observe(unknown, at: at(20), freeBytes: 60)
        precondition(values.run?.isClosed == false && values.run?.minimumFree == 80)
        // State survives a restart without claiming the stored phase is still live.
        values = try JSONDecoder().decode(BackupTracking.self, from: JSONEncoder().encode(values))
        values.observe(status("Finishing", session: start), at: at(30), freeBytes: 89)
        values.observe(idle, at: at(40), freeBytes: 92)
        precondition(values.run?.firstFree == 100 && values.run?.minimumFree == 80)
        precondition(values.run?.finalFree == 92 && values.run?.endedAt == at(40))
        precondition(values.run?.isClosed == true && values.run?.confirmedAt == nil)
        values.verify(saved(-1))
        values.verify(saved(33, id: "other"))
        precondition(values.run?.confirmedAt == nil)
        values.verify(saved(35))
        values.observe(idle, at: at(110), freeBytes: 50)
        precondition(values.latest?.completedAt == at(35) && values.run?.confirmedAt == at(35))
        precondition(values.run?.finalFree == 92 && values.run?.minimumFree == 80)
        // A backup skipped while the app was asleep must not inherit these measurements.
        values.verify(saved(290))
        precondition(values.latest?.completedAt == at(290) && values.run?.confirmedAt == at(35))

        values.observe(status("Copying", session: at(300)), at: at(310), freeBytes: nil)
        values.observe(status("Finishing", session: at(300)), at: at(340), freeBytes: 72)
        values.observe(idle, at: at(590), freeBytes: 8)
        precondition(values.run?.isClosed == true && values.run?.endedAt == nil)
        precondition(values.run?.firstFree == nil && values.run?.minimumFree == 72 && values.run?.finalFree == nil)
        values.verify(saved(570))
        precondition(values.run?.confirmedAt == nil)

        var changes = BackupTracking()
        changes.observe(status("Copying", session: at(0)), at: at(0), freeBytes: 20)
        changes.observe(status("Copying", session: at(100)), at: at(110), freeBytes: 70)
        precondition(changes.run?.minimumFree == 70 && changes.run?.firstAt == at(110))
        changes.observe(status("Copying", id: "other", session: at(100)), at: at(120), freeBytes: 100)
        precondition(changes.run?.destinationID == "other" && changes.run?.minimumFree == 100)
        changes.observe(idle, at: at(130), freeBytes: 0)
        precondition(changes.run?.finalFree == 0 && changes.run?.minimumFree == 0)
        changes.observe(status("Copying"), at: at(180), freeBytes: -1)
        precondition(changes.run?.firstFree == nil && changes.run?.minimumFree == nil)
        changes.observe(status("Copying"), at: at(400), freeBytes: 3)
        precondition(changes.run?.firstAt == at(400))
        print("PASS live phases, matched external saves, restart, missing samples and disk-space observations")
    }
}
