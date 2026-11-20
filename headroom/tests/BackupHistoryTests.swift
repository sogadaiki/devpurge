import Foundation

@main
enum BackupHistoryTests {
    static func main() {
        let save = BackupSaveEvidence(destinationID: "DISK-A", destinationName: "Time Machine",
                                      completedAt: Date(timeIntervalSince1970: 40), snapshotDate: nil)
        func row(_ second: Int, _ free: Int, active: Bool = true, disk: String = "disk-a") -> String {
            let date = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(second)))
            return #"{"time":"\#(date)","actual":\#(free),"state":{"Running":"\#(active ? "1" : "0")","DestinationID":"\#(disk)"}}"#
        }
        func match(_ lines: [String]) -> BackupRun? {
            BackupHistory.matchedRun(Data(lines.joined(separator: "\n").utf8), save: save)
        }
        let active = [row(5, 130), row(20, 98), row(35, 111)]
        let samples = active + [row(45, 119, active: false), row(60, 200, active: false)]
        let result = match(samples)
        precondition(result?.firstFree == 130 && result?.minimumFree == 98 && result?.finalFree == 119)
        precondition(result?.confirmedAt == save.completedAt)
        precondition(match(active) == nil && match(active + ["{}"]) == nil)
        precondition(match([row(5, 130, disk: "disk-b")] + samples.dropFirst()) == nil)
        precondition(match(active + [row(200, 140, active: false)]) == nil)
        precondition(match(samples + [row(70, 140)]) == nil)
        print("PASS backup history matches the destination and observed finish, rejects unrelated or interrupted watches")
    }
}
