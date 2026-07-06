import Foundation
import AppKit
import SoundRecorderKit

// A minimal Model Context Protocol server: JSON-RPC 2.0 messages, one per line,
// on stdin/stdout. Logs go to stderr (stdout must stay pure protocol traffic).
// No external dependencies — just Foundation.

final class MCPServer {
    private let session = RecorderSession()
    private let out = FileHandle.standardOutput

    func run() {
        log("nfl-sound-recorder-mcp ready")
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            handle(line)
        }
    }

    // MARK: JSON-RPC plumbing

    private func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("Ignoring non-JSON line: \(line)")
            return
        }
        guard let method = message["method"] as? String else { return } // a response; ignore
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]
        let isRequest = id != nil

        switch method {
        case "initialize":
            let clientProtocol = params["protocolVersion"] as? String
            sendResult(id: id, result: [
                "protocolVersion": clientProtocol ?? "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "nfl-sound-recorder", "version": "0.1.0"],
            ])
        case "ping":
            sendResult(id: id, result: [String: Any]())
        case "tools/list":
            sendResult(id: id, result: ["tools": Self.toolDefinitions])
        case "resources/list":
            sendResult(id: id, result: ["resources": [Any]()])
        case "prompts/list":
            sendResult(id: id, result: ["prompts": [Any]()])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let (text, isError) = callTool(name: name, arguments: args)
            sendResult(id: id, result: [
                "content": [["type": "text", "text": text]],
                "isError": isError,
            ])
        default:
            if isRequest { sendError(id: id, code: -32601, message: "Method not found: \(method)") }
        }
    }

    private func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        out.write(data)
        out.write(Data([0x0A]))
    }

    private func sendResult(id: Any?, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func sendError(id: Any?, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private func log(_ text: String) {
        FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
    }

    // MARK: Tools

    private func callTool(name: String, arguments: [String: Any]) -> (text: String, isError: Bool) {
        switch name {
        case "list_applications":
            let apps = AudioProcesses.list().map {
                ["name": $0.name, "bundleId": $0.bundleID, "pid": Int($0.pid), "isPlaying": $0.isPlaying] as [String: Any]
            }
            return (Self.json(["applications": apps]), false)

        case "list_output_devices":
            do {
                let defaultID = try? AudioSystem.defaultOutputDevice()
                let devices = try AudioSystem.outputDevices().map {
                    ["name": $0.name, "uid": $0.uid, "channels": $0.outputChannels, "isDefault": $0.id == defaultID] as [String: Any]
                }
                return (Self.json(["outputDevices": devices]), false)
            } catch {
                return ("Error listing devices: \(error)", true)
            }

        case "start_recording":
            return startRecording(arguments)

        case "set_equalizer":
            let enabled = arguments["enabled"] as? Bool
            let gains = (arguments["gains"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
            session.setEqualizer(enabled: enabled, gains: gains)
            return (Self.json([
                "equalizerEnabled": session.eqEnabled,
                "gains": session.eqGains,
                "centerFrequencies": GraphicEQ.centerFrequencies,
            ]), false)

        case "stop_recording":
            if let stopped = session.stop() {
                return (Self.json(["stopped": true, "file": stopped.url.path, "durationSeconds": Int(stopped.duration)]), false)
            }
            return ("Not currently recording.", true)

        case "recording_status":
            if let active = session.active {
                let elapsed = Int(Date().timeIntervalSince(active.startDate))
                return (Self.json([
                    "isRecording": true, "source": active.sourceLabel, "device": active.deviceName,
                    "file": active.fileURL.path, "elapsedSeconds": elapsed,
                    "framesCaptured": Int(active.recorder.meter.totalFrames),
                    "inputPeak": Double(active.recorder.meter.peak),
                    "equalizerEnabled": session.eqEnabled, "gains": session.eqGains,
                ]), false)
            }
            return (Self.json(["isRecording": false, "equalizerEnabled": session.eqEnabled, "gains": session.eqGains]), false)

        default:
            return ("Unknown tool: \(name)", true)
        }
    }

    private func startRecording(_ args: [String: Any]) -> (text: String, isError: Bool) {
        // Resolve the capture target.
        let target: ProcessTapRecorder.Target
        let label: String
        if let pid = args["pid"] as? Int {
            target = .pid(pid_t(pid))
            label = NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName ?? "pid \(pid)"
        } else {
            let source = (args["source"] as? String) ?? "system"
            if source.lowercased() == "system" {
                target = .systemWide
                label = "All System Audio"
            } else if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == source }) {
                target = .pid(app.processIdentifier)
                label = app.localizedName ?? source
            } else {
                return ("No running application with bundle id '\(source)'. Call list_applications first.", true)
            }
        }

        // Resolve the output device.
        let devices: [AudioDeviceInfo]
        do { devices = try AudioSystem.outputDevices() } catch { return ("Error listing devices: \(error)", true) }
        let device: AudioDeviceInfo
        if let uid = args["output_uid"] as? String {
            guard let match = devices.first(where: { $0.uid == uid }) else {
                return ("No output device with uid '\(uid)'. Call list_output_devices first.", true)
            }
            device = match
        } else {
            let defaultID = try? AudioSystem.defaultOutputDevice()
            guard let match = devices.first(where: { $0.id == defaultID }) ?? devices.first else {
                return ("No output devices available.", true)
            }
            device = match
        }

        let mute = (args["mute"] as? Bool) ?? false
        let driftCompensation = (args["drift_compensation"] as? Bool) ?? false
        let warmupSeconds = (args["warmup_seconds"] as? Double) ?? 0.6
        // Confined to the recordings directory — a client can choose a filename,
        // not an arbitrary path.
        let fileURL: URL = (args["file_path"] as? String).map {
            RecordingFiles.confinedURL(forRequestedPath: $0)
        } ?? RecordingFiles.newURL()

        do {
            try session.start(target: target, sourceLabel: label, device: device, mute: mute,
                              driftCompensation: driftCompensation, warmupSeconds: warmupSeconds,
                              fileURL: fileURL)
            return (Self.json([
                "started": true, "source": label, "device": device.name, "mute": mute,
                "driftCompensation": driftCompensation, "file": fileURL.path,
            ]), false)
        } catch {
            return ("Failed to start recording: \(error)", true)
        }
    }

    // MARK: Tool schemas

    private static func stringProp(_ desc: String) -> [String: Any] { ["type": "string", "description": desc] }

    static var toolDefinitions: [[String: Any]] { [
        [
            "name": "list_applications",
            "description": "List audio-first applications currently known to the system. Each entry has name, bundleId, pid, and isPlaying (whether it is producing audio right now). Re-enumerated live on every call.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ],
        [
            "name": "list_output_devices",
            "description": "List available audio output devices to route to. Each entry has name, uid, channels, and isDefault. Re-enumerated live on every call.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ],
        [
            "name": "start_recording",
            "description": "Start capturing audio to a file while routing it to an output device. Records one source at a time.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "source": stringProp("'system' for all system audio, or an application bundle id from list_applications. Defaults to 'system'."),
                    "pid": ["type": "integer", "description": "Optional process id to capture, overriding 'source'."],
                    "output_uid": stringProp("UID of the output device from list_output_devices. Defaults to the current default output."),
                    "mute": ["type": "boolean", "description": "If true, mute the source's normal output so only the routed copy is heard (reroute). Default false."],
                    "drift_compensation": ["type": "boolean", "description": "Resample the tap to the output clock. Default false; enabling can add a brief level ramp at the start."],
                    "warmup_seconds": ["type": "number", "description": "Hold off file-writing this long to skip Core Audio's device-start volume ramp. Default 0.6; use 0 to keep the raw ramp."],
                    "file_path": stringProp("Optional filename for the recording. Only the filename is used; writes are confined to ~/Music/NFL Sound Recorder/."),
                ],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "set_equalizer",
            "description": "Enable/disable the 10-band graphic EQ and set per-band gains in dB. Bands are centered at 32, 64, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz (low to high). Applies live if recording, otherwise to the next recording. Gains clamp to ±24 dB.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "enabled": ["type": "boolean", "description": "Turn the EQ on or off."],
                    "gains": ["type": "array", "items": ["type": "number"], "description": "Up to 10 per-band gains in dB, low to high frequency."],
                ],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "stop_recording",
            "description": "Stop the current recording and return the saved file path and duration.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ],
        [
            "name": "recording_status",
            "description": "Report whether a recording is in progress, and if so its source, device, file, and elapsed seconds.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ],
    ] }

    static func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

MCPServer().run()
