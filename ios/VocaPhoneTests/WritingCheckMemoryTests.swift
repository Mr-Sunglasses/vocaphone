import Darwin
import Foundation
import Testing

/// What Writing check costs the keyboard extension, whose memory limit was
/// measured at 77 MB on an iPhone 14 Pro: the rules parsed, and a check over a
/// long message. Opt in with `TEST_RUNNER_VOCA_MEMPROBE=1`; it prints rather
/// than asserts, because a simulator's footprint is not a phone's.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOCA_MEMPROBE"] == "1"))
struct WritingCheckMemoryTests {
    private static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    @Test func rulesAndACheckFitTheKeyboard() throws {
        let start = Self.footprint()
        let data = try Data(contentsOf: WritingCheckTests.root.appendingPathComponent("keyboard/writing-rules.json"))
        let rules = try WritingRules(data: data)
        let parsed = Self.footprint()
        let check = WritingCheck(rules: rules)
        let text = String(repeating: "I definately think your going to love it, its very good and I could of told you. ", count: 40)
        let clock = ContinuousClock()
        var report: WritingCheck.Report?
        let elapsed = clock.measure { report = check.check(text) }
        let checked = Self.footprint()
        print("WRITING_MEMPROBE start \(start) MB, rules +\(parsed - start) MB, check +\(checked - parsed) MB, "
            + "\(report?.suggestions.count ?? 0) suggestions over \(text.utf16Length) chars in \(elapsed)")
    }
}
