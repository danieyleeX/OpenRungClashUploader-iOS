import Foundation
import Network

struct FTPItem: Identifiable, Hashable {
    let name: String
    let isDirectory: Bool
    let size: Int64?
    var id: String { name }
}

enum FTPClientError: LocalizedError {
    case disconnected
    case badReply(String)
    case passiveModeUnavailable
    case invalidPath

    var errorDescription: String? {
        switch self {
        case .disconnected: return "FTP 连接已关闭。"
        case .badReply(let reply): return "FTP 服务器返回：\(reply)"
        case .passiveModeUnavailable: return "FTP 服务器未提供可用的被动传输端口。"
        case .invalidPath: return "FTP 路径中不能包含换行符或目录跳转。"
        }
    }
}

/// Basic passive FTP client used by the iOS file browser.
/// FTPS is deliberately not enabled here; the supplied server currently uses FTP.
final class FTPClient: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let username: String
    private let password: String
    private let queue = DispatchQueue(label: "org.openrung.clashuploader.ftp")
    private var control: NWConnection?
    private var controlBuffer = Data()

    init(host: String, port: UInt16, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    func connect() async throws {
        let connection = makeConnection(host: host, port: port)
        control = connection
        try await waitUntilReady(connection)
        let greeting = try await readReply()
        guard greeting.code == 220 else { throw FTPClientError.badReply(greeting.text) }
        let login = try await command("USER \(safeArgument(username))")
        if login.code == 331 {
            let authenticated = try await command("PASS \(safeArgument(password))")
            guard authenticated.code == 230 else { throw FTPClientError.badReply(authenticated.text) }
        } else if login.code != 230 {
            throw FTPClientError.badReply(login.text)
        }
        let type = try await command("TYPE I")
        guard type.code == 200 else { throw FTPClientError.badReply(type.text) }
    }

    func close() async {
        if let control {
            _ = try? await command("QUIT")
            control.cancel()
            self.control = nil
        }
    }

    func list(path: String) async throws -> [FTPItem] {
        try await changeDirectory(path)
        let data: Data
        do { data = try await dataCommand("MLSD") }
        catch { data = try await dataCommand("LIST") }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).compactMap { parseListing(String($0)) }
            .filter { $0.name != "." && $0.name != ".." }
            .sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func changeDirectory(_ path: String) async throws {
        try validate(path)
        let root = try await command("CWD /")
        guard root.code == 250 else { throw FTPClientError.badReply(root.text) }
        if !path.isEmpty {
            let result = try await command("CWD \(path)")
            guard result.code == 250 else { throw FTPClientError.badReply(result.text) }
        }
    }

    func createDirectory(_ path: String) async throws {
        try validate(path)
        let reply = try await command("MKD \(path)")
        guard reply.code == 257 || reply.code == 250 else { throw FTPClientError.badReply(reply.text) }
    }

    func delete(_ name: String, isDirectory: Bool) async throws {
        try validate(name)
        let reply = try await command("\(isDirectory ? "RMD" : "DELE") \(name)")
        guard reply.code == 250 else { throw FTPClientError.badReply(reply.text) }
    }

    func rename(_ oldName: String, to newName: String) async throws {
        try validate(oldName)
        try validate(newName)
        let from = try await command("RNFR \(oldName)")
        guard from.code == 350 else { throw FTPClientError.badReply(from.text) }
        let to = try await command("RNTO \(newName)")
        guard to.code == 250 else { throw FTPClientError.badReply(to.text) }
    }

    func upload(data: Data, as name: String) async throws {
        try validate(name)
        let dataConnection = try await openPassiveConnection()
        let start = try await sendCommand("STOR \(name)")
        guard start.code == 125 || start.code == 150 else {
            dataConnection.cancel()
            throw FTPClientError.badReply(start.text)
        }
        try await send(data, on: dataConnection)
        dataConnection.cancel()
        let finish = try await readReply()
        guard finish.code == 226 || finish.code == 250 else { throw FTPClientError.badReply(finish.text) }
    }

    func download(_ name: String) async throws -> Data {
        try validate(name)
        let dataConnection = try await openPassiveConnection()
        let start = try await sendCommand("RETR \(name)")
        guard start.code == 125 || start.code == 150 else {
            dataConnection.cancel()
            throw FTPClientError.badReply(start.text)
        }
        let data = try await receiveAll(on: dataConnection)
        dataConnection.cancel()
        let finish = try await readReply()
        guard finish.code == 226 || finish.code == 250 else { throw FTPClientError.badReply(finish.text) }
        return data
    }

    private func dataCommand(_ value: String) async throws -> Data {
        let dataConnection = try await openPassiveConnection()
        let start = try await sendCommand(value)
        guard start.code == 125 || start.code == 150 else {
            dataConnection.cancel()
            throw FTPClientError.badReply(start.text)
        }
        let data = try await receiveAll(on: dataConnection)
        dataConnection.cancel()
        let finish = try await readReply()
        guard finish.code == 226 || finish.code == 250 else { throw FTPClientError.badReply(finish.text) }
        return data
    }

    private func openPassiveConnection() async throws -> NWConnection {
        let reply = try await command("EPSV")
        let portValue: UInt16
        if let range = reply.text.range(of: #"\(\|\|\|([0-9]+)\|\)"#, options: .regularExpression),
           let parsed = UInt16(reply.text[range].filter(\.isNumber)) {
            portValue = parsed
        } else {
            let passive = try await command("PASV")
            guard let range = passive.text.range(of: #"\(([0-9]+,){5}[0-9]+\)"#, options: .regularExpression) else {
                throw FTPClientError.passiveModeUnavailable
            }
            let numbers = passive.text[range].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard numbers.count == 6, numbers.allSatisfy({ (0...255).contains($0) }) else { throw FTPClientError.passiveModeUnavailable }
            let parsed = numbers[4] * 256 + numbers[5]
            guard parsed > 0, let validPort = UInt16(exactly: parsed) else { throw FTPClientError.passiveModeUnavailable }
            portValue = validPort
        }
        let connection = makeConnection(host: host, port: portValue)
        try await waitUntilReady(connection)
        return connection
    }

    private func makeConnection(host: String, port: UInt16) -> NWConnection {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        return NWConnection(to: endpoint, using: .tcp)
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: FTPClientError.disconnected)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func command(_ text: String) async throws -> FTPReply {
        try await sendCommand(text)
    }

    private func sendCommand(_ text: String) async throws -> FTPReply {
        guard let control else { throw FTPClientError.disconnected }
        try await send(Data((text + "\r\n").utf8), on: control)
        return try await readReply()
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func readReply() async throws -> FTPReply {
        let first = try await readLine()
        guard first.count >= 3, let code = Int(first.prefix(3)) else { throw FTPClientError.badReply(first) }
        var lines = [first]
        if first.count > 3 && first[first.index(first.startIndex, offsetBy: 3)] == "-" {
            let terminator = String(format: "%03d ", code)
            while true {
                let line = try await readLine()
                lines.append(line)
                if line.hasPrefix(terminator) { break }
            }
        }
        return FTPReply(code: code, text: lines.joined(separator: "\n"))
    }

    private func readLine() async throws -> String {
        guard let control else { throw FTPClientError.disconnected }
        while true {
            if let range = controlBuffer.range(of: Data([13, 10])) {
                let lineData = controlBuffer[..<range.lowerBound]
                controlBuffer.removeSubrange(..<range.upperBound)
                return String(decoding: lineData, as: UTF8.self)
            }
            let (data, complete) = try await receiveChunk(on: control)
            controlBuffer.append(data)
            if complete && controlBuffer.isEmpty { throw FTPClientError.disconnected }
        }
    }

    private func receiveAll(on connection: NWConnection) async throws -> Data {
        var output = Data()
        while true {
            let (data, complete) = try await receiveChunk(on: connection)
            output.append(data)
            if complete { return output }
        }
    }

    private func receiveChunk(on connection: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (data ?? Data(), complete)) }
            }
        }
    }

    private func validate(_ path: String) throws {
        if path.contains("\r") || path.contains("\n") || path == "." || path == ".." || path.contains("/../") {
            throw FTPClientError.invalidPath
        }
    }

    private func safeArgument(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }

    private func parseListing(_ line: String) -> FTPItem? {
        let fields = line.split(separator: ";", omittingEmptySubsequences: false)
        if let last = fields.last, fields.contains(where: { $0.lowercased().hasPrefix("type=") }) {
            let facts = fields.dropLast().joined(separator: ";")
            let name = String(last).trimmingCharacters(in: .whitespaces)
            let isDirectory = facts.lowercased().contains("type=dir")
            let sizeText = fields.first(where: { $0.lowercased().hasPrefix("size=") }).map { String($0.dropFirst(5)) }
            return FTPItem(name: name, isDirectory: isDirectory, size: sizeText.flatMap(Int64.init))
        }
        let components = line.split(maxSplits: 8, whereSeparator: \.isWhitespace)
        guard components.count == 9, let permissions = components.first, permissions.count >= 10 else { return nil }
        let size = Int64(components[4])
        return FTPItem(name: String(components[8]), isDirectory: permissions.first == "d", size: size)
    }
}

private struct FTPReply {
    let code: Int
    let text: String
}
