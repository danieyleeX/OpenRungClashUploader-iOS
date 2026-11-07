import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var host = "t3.3vftp.vip"
    @Published var port = "3543"
    @Published var username = "au104745"
    @Published var password = ""
    @Published var remotePath = "wwwroot/clash.asp"
    @Published var clientID = UUID().uuidString
    @Published var yaml = ""
    @Published var log = "就绪"
    @Published var isBusy = false
    @Published var ftpItems: [FTPItem] = []
    @Published var ftpPath = ""
    @Published var showFTP = false
    @Published var alertMessage: String?
    private var ftp: FTPClient?

    init() {
        password = KeychainStore.readPassword()
        host = UserDefaults.standard.string(forKey: "ftp.host") ?? host
        port = UserDefaults.standard.string(forKey: "ftp.port") ?? port
        username = UserDefaults.standard.string(forKey: "ftp.user") ?? username
        remotePath = UserDefaults.standard.string(forKey: "ftp.path") ?? remotePath
    }

    func fetchOpenRung() { Task { await run { let result = try await OpenRungBrokerService().fetch(limit: 10, clientID: self.clientID); self.yaml = result.yaml; self.log = "OpenRung：目录 \(result.total) 个，兼容节点 \(result.compatible) 个，有效至 \(result.expires.formatted())" } } }
    func fetchZhuhai() { Task { await run { self.yaml = try await ZhuhaiSubscriptionService().fetch(); self.log = "已获取 Zhuhai 订阅（\(self.yaml.utf8.count) 字节）" } } }

    func upload() { Task { await run {
        guard let file = self.remotePath.split(separator: "/").last, !file.isEmpty else { throw FTPClientError.invalidPath }
        let directory = self.remotePath.split(separator: "/").dropLast().joined(separator: "/")
        let client = try await self.makeFTP()
        try await client.changeDirectory(directory)
        try await client.upload(data: Data(self.yaml.utf8), as: String(file))
        await client.close(); self.ftp = nil
        self.log = "已上传到 \(self.remotePath)"
    } } }

    func connectFTP() { Task { await run { let client = try await self.makeFTP(); self.ftpPath = ""; self.ftpItems = try await client.list(path: ""); self.showFTP = true; self.log = "FTP 已连接" } } }
    func openFolder(_ name: String) { Task { await run { let path = self.ftpPath.isEmpty ? name : "\(self.ftpPath)/\(name)"; self.ftpPath = path; self.ftpItems = try await self.requiredFTP().list(path: path) } } }
    func goFTPParent() { Task { await run { let path = self.ftpPath.split(separator: "/").dropLast().joined(separator: "/"); self.ftpPath = path; self.ftpItems = try await self.requiredFTP().list(path: path) } } }
    func refreshFTP() { Task { await run { self.ftpItems = try await self.requiredFTP().list(path: self.ftpPath) } } }
    func deleteFTP(_ item: FTPItem) { Task { await run { try await self.requiredFTP().changeDirectory(self.ftpPath); try await self.requiredFTP().delete(item.name, isDirectory: item.isDirectory); self.ftpItems = try await self.requiredFTP().list(path: self.ftpPath) } } }
    func renameFTP(_ item: FTPItem, to newName: String) { Task { await run { try await self.requiredFTP().changeDirectory(self.ftpPath); try await self.requiredFTP().rename(item.name, to: newName); self.ftpItems = try await self.requiredFTP().list(path: self.ftpPath) } } }
    func uploadPickedFile(_ data: Data, name: String) { Task { await run { try await self.requiredFTP().changeDirectory(self.ftpPath); try await self.requiredFTP().upload(data: data, as: name); self.ftpItems = try await self.requiredFTP().list(path: self.ftpPath) } } }
    func makeFolder(_ name: String) { Task { await run { try await self.requiredFTP().changeDirectory(self.ftpPath); try await self.requiredFTP().createDirectory(name); self.ftpItems = try await self.requiredFTP().list(path: self.ftpPath) } } }

    func saveSettings() { KeychainStore.savePassword(password); UserDefaults.standard.set(host, forKey: "ftp.host"); UserDefaults.standard.set(port, forKey: "ftp.port"); UserDefaults.standard.set(username, forKey: "ftp.user"); UserDefaults.standard.set(remotePath, forKey: "ftp.path"); log = "设置已保存" }
    private func makeFTP() async throws -> FTPClient { guard let number = UInt16(port) else { throw FTPClientError.badReply("端口必须是数字") }; let c = FTPClient(host: host, port: number, username: username, password: password); try await c.connect(); ftp = c; return c }
    private func requiredFTP() throws -> FTPClient { guard let ftp else { throw FTPClientError.disconnected }; return ftp }
    private func run(_ operation: @escaping () async throws -> Void) async { isBusy = true; defer { isBusy = false }; do { try await operation() } catch { alertMessage = error.localizedDescription; log = "失败：\(error.localizedDescription)" } }
}
