import Foundation
import Testing
@testable import LabBoxCore

private let kernel = URL(fileURLWithPath: "/images/vmlinuz")
private let initrd = URL(fileURLWithPath: "/images/initramfs")

private func host(
    cpus: Int = 8,
    memoryMB: Int = 16_384,
    files: Set<String> = ["/images/vmlinuz", "/images/initramfs"],
    gzip: Set<String> = [],
    zboot: Set<String> = []
) -> SandboxConfig.Host {
    SandboxConfig.Host(
        cpus: cpus,
        memoryMB: memoryMB,
        fileExists: { files.contains($0.path) },
        firstBytes: { url, _ in
            if gzip.contains(url.path) { return [0x1f, 0x8b, 8, 0, 0, 0, 0, 0] }
            if zboot.contains(url.path) { return [0x4d, 0x5a, 0, 0] + Array("zimg".utf8) }
            return [0x4d, 0x5a, 0x40, 0xfa, 0, 0, 0, 0]
        }
    )
}

@Test func zbootKernelIsRejected() {
    let config = SandboxConfig(kernel: kernel)
    #expect(config.problems(host: host(zboot: ["/images/vmlinuz"])) == [.compressedKernel(path: "/images/vmlinuz")])
}

@Test func defaultsAreValid() {
    let config = SandboxConfig(kernel: kernel, initrd: initrd)
    #expect(config.problems(host: host()).isEmpty)
}

@Test func missingKernelIsReported() {
    let config = SandboxConfig(kernel: kernel)
    #expect(config.problems(host: host(files: [])) == [.missingFile(role: "kernel", path: "/images/vmlinuz")])
}

@Test func missingInitrdAndDiskAreReported() {
    let disk = URL(fileURLWithPath: "/images/root.img")
    let config = SandboxConfig(kernel: kernel, initrd: initrd, disk: disk)
    #expect(config.problems(host: host(files: ["/images/vmlinuz"])) == [
        .missingFile(role: "initrd", path: "/images/initramfs"),
        .missingFile(role: "disk", path: "/images/root.img"),
    ])
}

@Test func gzipKernelIsRejected() {
    let config = SandboxConfig(kernel: kernel)
    #expect(config.problems(host: host(gzip: ["/images/vmlinuz"])) == [.compressedKernel(path: "/images/vmlinuz")])
}

@Test func cpuLimits() {
    #expect(SandboxConfig(kernel: kernel, cpus: 0).problems(host: host()) == [.cpusOutOfRange(asked: 0, max: 8)])
    #expect(SandboxConfig(kernel: kernel, cpus: 9).problems(host: host()) == [.cpusOutOfRange(asked: 9, max: 8)])
    #expect(SandboxConfig(kernel: kernel, cpus: 8).problems(host: host()).isEmpty)
}

@Test func memoryIsCappedAtHalfTheHost() {
    let h = host(memoryMB: 8192)
    #expect(SandboxConfig(kernel: kernel, memoryMB: 4096).problems(host: h).isEmpty)
    #expect(SandboxConfig(kernel: kernel, memoryMB: 4097).problems(host: h)
        == [.memoryOutOfRange(askedMB: 4097, minMB: 256, maxMB: 4096)])
    #expect(SandboxConfig(kernel: kernel, memoryMB: 128).problems(host: h)
        == [.memoryOutOfRange(askedMB: 128, minMB: 256, maxMB: 4096)])
}

@Test func timeoutMustBePositive() {
    #expect(SandboxConfig(kernel: kernel, timeoutSeconds: 0).problems(host: host()) == [.badTimeout(0)])
    #expect(SandboxConfig(kernel: kernel, timeoutSeconds: 30).problems(host: host()).isEmpty)
}

@Test func allProblemsComeBackTogether() {
    let config = SandboxConfig(kernel: kernel, cpus: 99, memoryMB: 1, timeoutSeconds: -5)
    #expect(config.problems(host: host(files: [])).count == 4)
}
