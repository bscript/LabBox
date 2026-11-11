import Foundation
import Virtualization

/// Boots one Linux VM and wires its console to a pair of file handles.
///
/// What the guest gets: CPU, memory, a console, entropy, and (if asked) one
/// disk image. What it does not get: a network card, shared folders, USB,
/// clipboard, audio. Adding any of those should be a visible decision.
///
/// Must be created and used on the main queue.
public final class VMRunner: NSObject, VZVirtualMachineDelegate {
    public enum Exit {
        case guestStopped
        case failed(Error)
        case killed(reason: String)
    }

    public enum SetupError: Error, CustomStringConvertible {
        case notSupported
        case invalid([SandboxConfig.Problem])

        public var description: String {
            switch self {
            case .notSupported:
                return "this Mac cannot run virtual machines (Virtualization.framework reports no support)"
            case let .invalid(problems):
                return problems.map { "- \($0)" }.joined(separator: "\n")
            }
        }
    }

    private let vm: VZVirtualMachine
    private let onExit: (Exit) -> Void
    private var finished = false

    /// Set when the VM was built with `controlChannel: true`.
    public let channel: GuestChannel?

    /// Host ends of the network port, set when built with `networkPort: true`.
    /// Hand them to a `NetGate`; without one the port goes nowhere.
    public let networkPipes: (toGuest: FileHandle, fromGuest: FileHandle)?

    public init(
        config: SandboxConfig,
        input: FileHandle,
        output: FileHandle,
        controlChannel: Bool = false,
        networkPort: Bool = false,
        onExit: @escaping (Exit) -> Void
    ) throws {
        guard VZVirtualMachine.isSupported else { throw SetupError.notSupported }
        let problems = config.problems()
        guard problems.isEmpty else { throw SetupError.invalid(problems) }

        let boot = VZLinuxBootLoader(kernelURL: config.kernel)
        boot.initialRamdiskURL = config.initrd
        boot.commandLine = config.commandLine

        let vz = VZVirtualMachineConfiguration()
        vz.bootLoader = boot
        vz.cpuCount = config.cpus
        vz.memorySize = UInt64(config.memoryMB) * 1_048_576

        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: input,
            fileHandleForWriting: output
        )
        vz.serialPorts = [serial]
        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        if let disk = config.disk {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: config.diskReadOnly)
            vz.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        }

        // The control channel is one named virtio console port backed by two
        // pipes. It is a plain byte stream: no sockets, no addresses.
        var channel: GuestChannel?
        var networkPipes: (toGuest: FileHandle, fromGuest: FileHandle)?
        if controlChannel {
            let toGuest = Pipe()
            let fromGuest = Pipe()
            let port = VZVirtioConsolePortConfiguration()
            port.name = GuestProtocol.controlPortName
            port.isConsole = false
            port.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: toGuest.fileHandleForReading,
                fileHandleForWriting: fromGuest.fileHandleForWriting
            )
            let device = VZVirtioConsoleDeviceConfiguration()
            device.ports[0] = port

            // Still no network card. This is a second byte stream, and the
            // host decides what, if anything, is on the other end of it.
            if networkPort {
                let netToGuest = Pipe()
                let netFromGuest = Pipe()
                let net = VZVirtioConsolePortConfiguration()
                net.name = GuestProtocol.netPortName
                net.isConsole = false
                net.attachment = VZFileHandleSerialPortAttachment(
                    fileHandleForReading: netToGuest.fileHandleForReading,
                    fileHandleForWriting: netFromGuest.fileHandleForWriting
                )
                device.ports[1] = net
                networkPipes = (netToGuest.fileHandleForWriting, netFromGuest.fileHandleForReading)
            }
            vz.consoleDevices = [device]
            channel = GuestChannel(
                toGuest: toGuest.fileHandleForWriting,
                fromGuest: fromGuest.fileHandleForReading
            )
        }

        // Deliberately empty: no network, no shared directories.
        vz.networkDevices = []
        vz.directorySharingDevices = []

        try vz.validate()

        self.vm = VZVirtualMachine(configuration: vz)
        self.onExit = onExit
        self.channel = channel
        self.networkPipes = networkPipes
        super.init()
        self.vm.delegate = self
        channel?.start()

        if let t = config.timeoutSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(t)) { [weak self] in
                self?.kill(reason: "time limit of \(t)s reached")
            }
        }
    }

    public func start() {
        vm.start { [weak self] result in
            if case let .failure(error) = result { self?.finish(.failed(error)) }
        }
    }

    /// Hard stop. Does not ask the guest; it just ends.
    public func kill(reason: String) {
        guard !finished else { return }
        guard vm.canStop else {
            finish(.killed(reason: reason))
            return
        }
        vm.stop { [weak self] _ in
            // Even if stop reports an error we report "killed": the caller
            // exits the process, which tears the VM down regardless.
            self?.finish(.killed(reason: reason))
        }
    }

    private func finish(_ exit: Exit) {
        guard !finished else { return }
        finished = true
        onExit(exit)
    }

    // MARK: VZVirtualMachineDelegate

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        finish(.guestStopped)
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        finish(.failed(error))
    }
}
