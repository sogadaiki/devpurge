import Foundation

@main
struct BackupProbeTests {
    static func main() throws {
        let status = BackupProbe.parseStatus(Data("""
        Backup session status:
        {
            DateOfStateChange = "2026-11-20 02:47:07 +0000";
            DestinationID = "target-A";
            DestinationMountPoint = "/Volumes/Test Drive";
            BackupPhase = Copying;
            Progress = { Percent = "0.02"; };
            Running = 1;
        }
        """.utf8))
        precondition(status.running == true && status.phase == "Copying" && status.destinationID == "target-A")
        precondition(status.destinationName == "Test Drive" && status.sessionStart != nil)
        precondition(BackupProbe.parseStatus(Data("{ Running = 0; }".utf8)).running == false)
        precondition(BackupProbe.parseStatus(Data("permission denied".utf8)).running == nil)
        precondition(BackupProbe.parseStatus(nil).running == nil)

        let volume = "10000000-0000-0000-0000-000000000001"
        let point = "2026-11-20-122808.backup"
        let generation = BackupProbe.Generation([
            "DestinationID": "target-A", "LastKnownVolumeName": "Drive A", "DestinationUUIDs": [volume],
            "SnapshotDates": [Date(timeIntervalSince1970: 1_795_145_288)],
        ])!
        func match(_ path: String, _ timestamp: String = "2026-11-20 12:30:38.495221+0900",
                   _ prefix: String = "Successfully completed backing up") throws -> BackupSaveEvidence? {
            let event = ["timestamp": timestamp, "eventMessage": "\(prefix) 1 GB to '\(path)'"]
            return BackupProbe.matchSuccess(try JSONSerialization.data(withJSONObject: event),
                                            generation: generation, name: point)
        }
        let root = "/Volumes/.timemachine/\(volume)/"
        let saved = try match(root + point + "/" + point)
        precondition(saved?.destinationID == "target-A" && saved?.snapshotDate == generation.date)
        precondition(saved.map { abs($0.completedAt.timeIntervalSince1970 - 1_795_145_438.495) < 0.01 } == true)
        let singlePath = try match(root + point)
        precondition(singlePath == saved)
        for badPath in [
            "/Volumes/.timemachine/20000000-0000-0000-0000-000000000002/" + point,
            root + "2026-11-17-132353.backup", root + point + "/unexpected",
            root + "com.apple.TimeMachine.2026-11-20-122808.local", "/Volumes/Drive A/" + point,
        ] {
            let result = try match(badPath)
            precondition(result == nil)
        }
        let early = try match(root + point, "2026-11-20 12:20:00.000000+0900")
        let unfinished = try match(root + point, "2026-11-20 12:30:38.495221+0900", "Started copying")
        precondition(early == nil && unfinished == nil)
        print("PASS Time Machine status, unknown, external destination and generation matching, actual completion timestamp")
    }
}
