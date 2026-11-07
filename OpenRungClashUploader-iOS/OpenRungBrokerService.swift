import CryptoKit
import Foundation

struct RelayList: Decodable {
    let channel: String
    let count: Int
    let limit: Int
    let notAfter: Date
    let relays: [Relay]

    enum CodingKeys: String, CodingKey {
        case channel, count, limit, relays
        case notAfter = "not_after"
    }
}

struct Relay: Decodable {
    let id: String
    let label: String
    let publicHost: String
    let publicPort: Int
    let countryCode: String
    let protocolName: String
    let clientId: String
    let realityPublicKey: String
    let shortId: String
    let serverName: String
    let flow: String
    let transport: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id, label, flow, transport
        case publicHost = "public_host"
        case publicPort = "public_port"
        case countryCode = "country_code"
        case protocolName = "protocol"
        case clientId = "client_id"
        case realityPublicKey = "reality_public_key"
        case shortId = "short_id"
        case serverName = "server_name"
        case expiresAt = "expires_at"
    }
}

struct OpenRungFetchResult {
    let yaml: String
    let total: Int
    let compatible: Int
    let expires: Date
}

enum SubscriptionError: LocalizedError {
    case noCompatibleNodes
    case invalidDirectory(String)
    case invalidSubscription

    var errorDescription: String? {
        switch self {
        case .noCompatibleNodes: return "目录没有可转换为 Mihomo 的直接 VLESS + REALITY 节点。"
        case .invalidDirectory(let reason): return "OpenRung 节点目录无效：\(reason)"
        case .invalidSubscription: return "下载内容不像 Clash YAML 订阅。"
        }
    }
}

struct OpenRungBrokerService {
    private let bases = [
        "https://broker.openrung.org/",
        "https://d2r7mdpyevvs1m.cloudfront.net/",
        "https://cdn-edge-cxdnhsg2aadmaubj.z02.azurefd.net/"
    ]
    private let activeKey = Data(hex: "176c03cbc70833285abcea75f2a0e137bd687629142408c22806a86308bd4974")!
    private let standbyKey = Data(hex: "5b2698cfa7a796c671a30aabd5475d55095b91464221f051837eb8fe01f36ea2")!

    func fetch(limit: Int, clientID: String) async throws -> OpenRungFetchResult {
        var errors: [String] = []
        for base in bases {
            do {
                var components = URLComponents(string: base + "api/v1/relays")!
                components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
                var request = URLRequest(url: components.url!, timeoutInterval: 20)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
                request.setValue("1.0.0", forHTTPHeaderField: "X-OpenRung-App-Version")
                request.setValue("ios", forHTTPHeaderField: "X-OpenRung-Platform")
                request.setValue(clientID, forHTTPHeaderField: "X-OpenRung-Client-ID")
                request.setValue(UUID().uuidString, forHTTPHeaderField: "X-OpenRung-Session-ID")

                let (body, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    errors.append("\(URL(string: base)!.host ?? base): HTTP \(code)")
                    continue
                }
                guard let signatureHeader = http.value(forHTTPHeaderField: "X-OpenRung-Relays-Signature") else {
                    errors.append("\(URL(string: base)!.host ?? base): 缺少签名头")
                    continue
                }
                try verify(signatureHeader: signatureHeader, body: body)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .custom { decoder in
                    let value = try decoder.singleValueContainer().decode(String.self)
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let date = formatter.date(from: value) { return date }
                    formatter.formatOptions = [.withInternetDateTime]
                    if let date = formatter.date(from: value) { return date }
                    throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid ISO-8601 date")
                }
                let directory = try decoder.decode(RelayList.self, from: body)
                guard directory.channel == "api", directory.limit == limit,
                      directory.count == directory.relays.count,
                      directory.notAfter > Date().addingTimeInterval(-300) else {
                    throw SubscriptionError.invalidDirectory("目录参数、数量或有效期不匹配。")
                }
                let proxies = directory.relays.filter {
                    $0.protocolName == "vless-reality-vision" &&
                    ($0.transport.isEmpty || $0.transport == "direct") &&
                    !$0.publicHost.isEmpty && (1...65535).contains($0.publicPort) &&
                    !$0.clientId.isEmpty && !$0.realityPublicKey.isEmpty &&
                    !$0.serverName.isEmpty && $0.expiresAt > Date()
                }
                guard !proxies.isEmpty else { throw SubscriptionError.noCompatibleNodes }
                let yaml = render(proxies)
                return OpenRungFetchResult(yaml: yaml, total: directory.count, compatible: proxies.count, expires: directory.notAfter)
            } catch {
                errors.append("\(URL(string: base)!.host ?? base): \(error.localizedDescription)")
            }
        }
        throw NSError(domain: "OpenRungBroker", code: -1, userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: "；")])
    }

    private func verify(signatureHeader: String, body: Data) throws {
        let parts = signatureHeader.split(separator: ";")
        guard parts.count == 3, String(parts[0]) == "ed25519", let signature = Data(base64Encoded: String(parts[2])), signature.count == 64 else {
            throw SubscriptionError.invalidDirectory("签名头格式错误。")
        }
        for key in [activeKey, standbyKey] {
            let identifier = SHA256.hash(data: key).prefix(8).map { String(format: "%02x", $0) }.joined()
            guard identifier == String(parts[1]) else { continue }
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
            guard publicKey.isValidSignature(signature, for: body) else {
                throw SubscriptionError.invalidDirectory("签名校验失败。")
            }
            return
        }
        throw SubscriptionError.invalidDirectory("找不到匹配的 OpenRung 签名公钥。")
    }

    private func render(_ relays: [Relay]) -> String {
        var output = "# OpenRung signed relay candidates\nproxies:\n"
        for relay in relays {
            let suffix = relay.countryCode.isEmpty ? relay.label : relay.countryCode
            let label = relay.label.isEmpty ? relay.id : "\(relay.label) (\(suffix))"
            output += "  - name: \(yamlQuote(label))\n"
            output += "    type: vless\n    server: \(yamlQuote(relay.publicHost))\n"
            output += "    port: \(relay.publicPort)\n    uuid: \(yamlQuote(relay.clientId))\n"
            output += "    network: tcp\n    udp: true\n    tls: true\n"
            output += "    servername: \(yamlQuote(relay.serverName))\n    client-fingerprint: chrome\n"
            output += "    flow: \(yamlQuote(relay.flow.isEmpty ? "xtls-rprx-vision" : relay.flow))\n"
            output += "    reality-opts:\n      public-key: \(yamlQuote(relay.realityPublicKey))\n"
            output += "      short-id: \(yamlQuote(relay.shortId))\n"
        }
        output += "\nproxy-groups:\n  - name: OpenRung\n    type: select\n    proxies:\n"
        for relay in relays {
            let suffix = relay.countryCode.isEmpty ? relay.label : relay.countryCode
            output += "      - \(yamlQuote(relay.label.isEmpty ? relay.id : "\(relay.label) (\(suffix))"))\n"
        }
        output += "\nrules:\n"
        output += "  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve\n"
        output += "  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve\n"
        output += "  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve\n"
        output += "  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve\n"
        output += "  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve\n"
        output += "  - IP-CIDR6,::1/128,DIRECT,no-resolve\n"
        output += "  - IP-CIDR6,fc00::/7,DIRECT,no-resolve\n"
        output += "  - IP-CIDR6,fe80::/10,DIRECT,no-resolve\n"
        output += "  - GEOSITE,CN,DIRECT\n  - GEOIP,CN,DIRECT,no-resolve\n  - MATCH,OpenRung\n"
        return output
    }

    private func yamlQuote(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(value)\""
    }
}

struct ZhuhaiSubscriptionService {
    func fetch() async throws -> String {
        let url = URL(string: "https://raw.githubusercontent.com/zhuhaiuk/free-nodes/main/clash_config.yaml")!
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 5_000_000, let yaml = String(data: data, encoding: .utf8),
              yaml.contains("proxies:"), yaml.contains("rules:") else {
            throw SubscriptionError.invalidSubscription
        }
        return yaml
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
