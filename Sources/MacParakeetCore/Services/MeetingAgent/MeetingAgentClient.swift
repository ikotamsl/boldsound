import Darwin
import Foundation

public protocol MeetingAgentClientProtocol: Sendable {
    func call(_ command: String, payload: MeetingAgentJSON?, configuration: MeetingAgentConfiguration) async throws
        -> MeetingAgentJSON
}

/// Each request runs without a shell. File-backed stdio prevents pipe deadlocks
/// for long transcripts, while all private temporary files are removed on exit.
public actor MeetingAgentClient: MeetingAgentClientProtocol {
    private let timeout: TimeInterval
    public init(timeout: TimeInterval = 20) { self.timeout = timeout }

    public func call(_ command: String, payload: MeetingAgentJSON?, configuration: MeetingAgentConfiguration)
        async throws -> MeetingAgentJSON
    {
        let allowed = [
            "enqueue", "jobs", "profiles", "notes", "doctor", "retry", "cancel", "bind", "invalidate", "login",
            "launchd",
        ]
        guard allowed.contains(command), (configuration.executablePath as NSString).isAbsolutePath,
            FileManager.default.isExecutableFile(atPath: configuration.executablePath)
        else {
            throw MeetingAgentError.unavailable
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "boldsound-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.json")
        let outputURL = directory.appendingPathComponent("output.json")
        let input = try payload.map { try MeetingAgentJSON.encoder().encode($0) } ?? Data()
        FileManager.default.createFile(atPath: inputURL.path, contents: input, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdin = try FileHandle(forReadingFrom: inputURL)
        let stdout = try FileHandle(forWritingTo: outputURL)
        let stderr = FileHandle.nullDevice
        defer { try? stdin.close(); try? stdout.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        var arguments = ["--vault", configuration.vaultPath]
        if let profileID = configuration.profileID, !profileID.isEmpty { arguments += ["--profile", profileID] }
        arguments.append(command)
        if payload != nil, ["jobs", "profiles", "notes", "doctor", "retry", "cancel"].contains(command) {
            arguments.append("--stdin")
        }
        if command == "launchd" { arguments.append("--install") }
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // The app never passes API credentials in its environment or arguments.
        process.environment = ProcessInfo.processInfo.environment.filter {
            ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL"].contains($0.key)
        }
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let deadline = Date().addingTimeInterval(command == "doctor" ? 180 : timeout)
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { throw MeetingAgentError.timeout }
            try await Task.sleep(for: .milliseconds(40))
        }
        let data = try Data(contentsOf: outputURL)
        guard let envelope = try? JSONDecoder().decode(MeetingAgentJSON.self, from: data),
            envelope["schema_version"] == .number(1)
        else {
            throw MeetingAgentError.invalidResponse
        }
        guard envelope["ok"].bool, process.terminationStatus == 0 else {
            throw MeetingAgentError.agent(envelope["error"]["message"].string ?? "Ошибка агента встреч.")
        }
        return envelope["data"]
    }
}
