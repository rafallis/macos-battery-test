// battery-spoof — macOS battery cycle count spoofer via DYLD interposition.
//
// REQUIREMENTS:
//   - SIP disabled (`csrutil disable` from Recovery Mode)
//   - For Apple system apps (System Settings, etc.) also add boot-arg:
//       `sudo nvram boot-args="amfi_get_out_of_my_way=1"`
//     then reboot.
//   - Run as root or with `sudo` when launching hardened apps.
//
// USAGE:
//   battery-spoof read
//   battery-spoof run --count 999 -- ioreg -l -n AppleSmartBattery
//   battery-spoof run --count 999 -- system_profiler SPPowerDataType
//   battery-spoof launch --count 999 --app "System Settings"
//   battery-spoof launch --count 999 --app "coconutBattery"

import ArgumentParser
import Foundation
import IOKit

// ---------------------------------------------------------------------------
// Root command
// ---------------------------------------------------------------------------
@main
struct BatterySpoof: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "battery-spoof",
        abstract: "Spoof macOS battery CycleCount via DYLD interposition.",
        discussion: """
        Injects a Rust dylib into target processes so that IOKit reads for
        "CycleCount" return a user-supplied value instead of the hardware value.

        The change is per-process and lasts until that process exits.
        No kernel modifications are made.

        NOTE: Requires SIP disabled.  To inject into Apple hardened-runtime
        apps (System Settings) also set the boot-arg:
          sudo nvram boot-args="amfi_get_out_of_my_way=1"
        """,
        subcommands: [Read.self, Run.self, Launch.self, TestHook.self, TestChild.self],
        defaultSubcommand: Read.self
    )
}

// ---------------------------------------------------------------------------
// Subcommand: read — print hardware cycle count
// ---------------------------------------------------------------------------
struct Read: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read the current hardware battery cycle count."
    )

    func run() throws {
        let count = try readHardwareCycleCount()
        print("CycleCount: \(count)")
    }
}

// ---------------------------------------------------------------------------
// Subcommand: run — run a CLI command with the dylib injected
// ---------------------------------------------------------------------------
struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a shell command with CycleCount spoofed."
    )

    @Option(name: .shortAndLong, help: "The cycle count value to report.")
    var count: Int

    @Argument(parsing: .captureForPassthrough, help: "Command and arguments to run.")
    var commandAndArgs: [String] = []

    func validate() throws {
        guard count >= 0 && count <= 100_000 else {
            throw ValidationError("--count must be between 0 and 100000.")
        }
        guard !commandAndArgs.isEmpty else {
            throw ValidationError("Provide a command to run after --.")
        }
    }

    func run() throws {
        let dylibPath = try bundledDylibPath()
        let command = commandAndArgs[0]
        let args = Array(commandAndArgs.dropFirst())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        process.environment = buildEnvironment(
            dylibPath: dylibPath,
            cycleCount: count,
            base: ProcessInfo.processInfo.environment
        )

        try process.run()
        process.waitUntilExit()

        let status = process.terminationStatus
        if status != 0 {
            throw ExitCode(status)
        }
    }
}

// ---------------------------------------------------------------------------
// Subcommand: launch — open a macOS .app bundle with the dylib injected
// ---------------------------------------------------------------------------
struct Launch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Launch a macOS app bundle with CycleCount spoofed."
    )

    @Option(name: .shortAndLong, help: "The cycle count value to report.")
    var count: Int

    @Option(name: .shortAndLong, help: "App name (e.g. \"System Settings\") or full .app path.")
    var app: String

    @Flag(name: .long, help: "Terminate the app first if it is already running.")
    var terminate: Bool = true

    func validate() throws {
        guard count >= 0 && count <= 100_000 else {
            throw ValidationError("--count must be between 0 and 100000.")
        }
    }

    func run() throws {
        let dylibPath = try bundledDylibPath()

        // Resolve full .app URL
        let appURL = try resolveAppURL(app)

        // Optionally terminate existing instance
        if terminate {
            terminateRunningInstances(bundleURL: appURL)
        }

        let env = buildEnvironment(
            dylibPath: dylibPath,
            cycleCount: count,
            base: [:]  // do NOT inherit parent env — avoids re-injecting
        )

        let config = NSWorkspace.OpenConfiguration()
        config.environment = env
        config.activates = true
        config.promptsUserIfNeeded = false

        let semaphore = DispatchSemaphore(value: 0)
        var launchError: Error? = nil

        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: config
        ) { _, error in
            launchError = error
            semaphore.signal()
        }

        semaphore.wait()

        if let error = launchError {
            throw error
        }

        print("Launched \(appURL.lastPathComponent) with CycleCount=\(count)")
    }
}

// ---------------------------------------------------------------------------
// IOKit helpers
// ---------------------------------------------------------------------------

/// Read CycleCount directly from the IORegistry (no dylib involved).
func readHardwareCycleCount() throws -> Int {
    let service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("AppleSmartBattery")
    )
    guard service != IO_OBJECT_NULL else {
        throw BatterySpoofError.noBatteryFound
    }
    defer { IOObjectRelease(service) }

    guard let cfValue = IORegistryEntryCreateCFProperty(
        service,
        "CycleCount" as CFString,
        kCFAllocatorDefault,
        0
    )?.takeRetainedValue() as? NSNumber else {
        throw BatterySpoofError.propertyNotFound("CycleCount")
    }

    return cfValue.intValue
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Returns the path to the bundled libcyclecount.dylib.
private func bundledDylibPath() throws -> String {
    guard let url = Bundle.module.url(
        forResource: "libcyclecount",
        withExtension: "dylib"
    ) else {
        throw BatterySpoofError.dylibNotFound
    }
    return url.path
}

/// Build the child process environment with DYLD vars set.
private func buildEnvironment(
    dylibPath: String,
    cycleCount: Int,
    base: [String: String]
) -> [String: String] {
    var env = base
    // Avoid stacking multiple dylib paths if already set.
    let existing = env["DYLD_INSERT_LIBRARIES"].flatMap { $0.isEmpty ? nil : Optional($0) }
    if let existing = existing {
        env["DYLD_INSERT_LIBRARIES"] = "\(dylibPath):\(existing)"
    } else {
        env["DYLD_INSERT_LIBRARIES"] = dylibPath
    }
    env["MACBATTERY_CYCLE_COUNT"] = "\(cycleCount)"
    return env
}

/// Resolve an app name or path to a URL.
private func resolveAppURL(_ nameOrPath: String) throws -> URL {
    // If it looks like an absolute path, use it directly.
    if nameOrPath.hasPrefix("/") {
        let url = URL(fileURLWithPath: nameOrPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BatterySpoofError.appNotFound(nameOrPath)
        }
        return url
    }

    // Try NSWorkspace lookup by name.
    let name = nameOrPath.hasSuffix(".app") ? nameOrPath : "\(nameOrPath).app"
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "") {
        // urlForApplication(withBundleIdentifier:) doesn't help with names;
        // fall through to path-based search.
        _ = url
    }

    // Search common application directories.
    let searchDirs = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]
    for dir in searchDirs {
        let candidate = (dir as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
    }

    throw BatterySpoofError.appNotFound(nameOrPath)
}

/// Terminate all running instances of the app at the given URL.
private func terminateRunningInstances(bundleURL: URL) {
    let canonicalPath = bundleURL.standardized.path
    let running = NSWorkspace.shared.runningApplications.filter {
        $0.bundleURL.map { $0.standardized.path == canonicalPath } ?? false
    }
    for app in running {
        app.terminate()
    }
    // Give apps a moment to terminate gracefully.
    if !running.isEmpty {
        Thread.sleep(forTimeInterval: 0.8)
    }
}

// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------
enum BatterySpoofError: LocalizedError {
    case noBatteryFound
    case propertyNotFound(String)
    case dylibNotFound
    case appNotFound(String)

    var errorDescription: String? {
        switch self {
        case .noBatteryFound:
            return "AppleSmartBattery IOService not found — is this a Mac with a battery?"
        case .propertyNotFound(let key):
            return "IORegistry property '\(key)' not found."
        case .dylibNotFound:
            return """
            libcyclecount.dylib not found in bundle resources.
            Run build.sh first to compile the Rust dylib and copy it into place.
            """
        case .appNotFound(let name):
            return "Application '\(name)' not found in standard locations."
        }
    }
}

// ---------------------------------------------------------------------------
// Subcommand: test-hook — verify dylib injection works (VM-safe)
// ---------------------------------------------------------------------------
struct TestHook: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test-hook",
        abstract: "Verify dylib injection pipeline works on this machine (VM-safe).",
        discussion: """
        Spawns a child process of this binary with the Rust dylib injected and
        asks it to call IORegistryEntryCreateCFProperty("CycleCount") via
        IOPlatformExpertDevice, which is present on every Mac including VMs.

        If the hook fires, the child receives the spoofed value (42) instead of
        nil and exits 0.  This confirms the full injection pipeline is working
        without needing real battery hardware.
        """
    )

    func run() throws {
        let dylibPath = try bundledDylibPath()
        let sentinel = 42

        // Re-exec ourselves as the hidden child subcommand.
        guard let execPath = Bundle.main.executableURL?.path
                ?? ProcessInfo.processInfo.arguments.first.map({ $0 })
        else {
            throw BatterySpoofError.propertyNotFound("executable path")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = ["_test-child"]
        process.environment = buildEnvironment(
            dylibPath: dylibPath,
            cycleCount: sentinel,
            base: ProcessInfo.processInfo.environment
        )

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let outText = String(data: outData, encoding: .utf8) ?? ""
        let errText = String(data: errData, encoding: .utf8) ?? ""

        if process.terminationStatus == 0 {
            print("[PASS] Hook fired successfully — dylib injection works on this machine.")
            if !outText.isEmpty { print(outText, terminator: "") }
        } else {
            print("[FAIL] Hook did NOT fire (exit \(process.terminationStatus)).")
            if !outText.isEmpty { print(outText, terminator: "") }
            if !errText.isEmpty { FileHandle.standardError.write(Data(errText.utf8)) }
            throw ExitCode(1)
        }
    }
}

// ---------------------------------------------------------------------------
// Hidden child subcommand — runs inside the injected process
// ---------------------------------------------------------------------------
struct TestChild: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_test-child",
        shouldDisplay: false   // hidden from --help
    )

    func run() throws {
        let expected = Int(
            ProcessInfo.processInfo.environment["MACBATTERY_CYCLE_COUNT"] ?? ""
        ) ?? -1

        // IOPlatformExpertDevice is always present — in VMs and on real Macs.
        // The hook intercepts by key name alone, regardless of which service is
        // passed, so this gives us a clean signal that the dylib was loaded.
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != IO_OBJECT_NULL else {
            FileHandle.standardError.write(
                Data("ERROR: IOPlatformExpertDevice not found\n".utf8)
            )
            throw ExitCode(2)
        }
        defer { IOObjectRelease(service) }

        // Call with key "CycleCount".  The real IOKit will return nil for
        // this service (it has no such property), but our hook intercepts
        // the key name and returns the spoofed CFNumber instead.
        let result = IORegistryEntryCreateCFProperty(
            service,
            "CycleCount" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber

        if let result = result, result.intValue == expected {
            print("  IORegistryEntryCreateCFProperty(\"CycleCount\") → \(result.intValue) (expected \(expected)) ✓")
        } else {
            let got = result.map { String($0.intValue) } ?? "nil"
            FileHandle.standardError.write(
                Data("  Hook did not fire: got \(got), expected \(expected)\n".utf8)
            )
            throw ExitCode(1)
        }
    }
}
