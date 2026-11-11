import Foundation
import Security
import Virtualization

/// Checks that this Mac and this binary can run a sandbox.
public enum Doctor {
    public struct Check {
        public let name: String
        public let ok: Bool
        public let detail: String
    }

    public static let virtualizationEntitlement = "com.apple.security.virtualization"

    public static func run() -> [Check] {
        var checks: [Check] = []

        #if arch(arm64)
        checks.append(Check(name: "Apple silicon", ok: true, detail: "arm64"))
        #else
        checks.append(Check(name: "Apple silicon", ok: false, detail: "LabBox only targets arm64 Macs"))
        #endif

        checks.append(Check(
            name: "Virtualization support",
            ok: VZVirtualMachine.isSupported,
            detail: VZVirtualMachine.isSupported ? "available" : "not available on this Mac"
        ))

        let signed = hasEntitlement(virtualizationEntitlement)
        checks.append(Check(
            name: "Signed with VM entitlement",
            ok: signed,
            detail: signed ? virtualizationEntitlement : "missing; build with scripts/build.sh"
        ))

        let fm = FileManager.default
        let kernel = fm.fileExists(atPath: LabBoxPaths.defaultKernel.path)
        let initrd = fm.fileExists(atPath: LabBoxPaths.defaultInitrd.path)
        checks.append(Check(
            name: "Default Linux image",
            ok: kernel && initrd,
            detail: kernel && initrd ? LabBoxPaths.images.path : "not downloaded; run scripts/fetch-alpine.sh"
        ))

        let agent = fm.fileExists(atPath: LabBoxPaths.agentInitrd.path)
        checks.append(Check(
            name: "Guest agent ramdisk",
            ok: agent,
            detail: agent ? LabBoxPaths.agentInitrd.path : "not built; run scripts/build-guest.sh"
        ))

        return checks
    }

    static func hasEntitlement(_ name: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, name as CFString, nil)
        return (value as? Bool) == true
    }
}
