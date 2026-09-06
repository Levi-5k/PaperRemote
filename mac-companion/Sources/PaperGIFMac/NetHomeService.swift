import Foundation
import Security

struct NetHomeUnit: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

private struct NetHomeCredentials: Codable {
    let account: String
    let password: String
}

private enum NetHomeKeychain {
    static let service = "human-programs.paperGIF.netHome"
    static let account = "credentials"

    static func load() -> NetHomeCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(NetHomeCredentials.self, from: data)
    }

    static func save(_ credentials: NetHomeCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}

final class NetHomeService: @unchecked Sendable {
    private static let packageVersion = "0.10.7"
    private let operationLock = NSLock()

    var isSignedIn: Bool { NetHomeKeychain.load() != nil }
    var account: String? { NetHomeKeychain.load()?.account }

    func signIn(account: String, password: String) throws -> [String] {
        let credentials = NetHomeCredentials(
            account: account.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
        guard !credentials.account.isEmpty, !credentials.password.isEmpty else {
            throw serviceError("Enter both your NetHome account and password.")
        }
        let devices = try listUnits(credentials: credentials)
        guard !devices.isEmpty else {
            throw serviceError("The NetHome account has no supported air conditioners.")
        }
        try NetHomeKeychain.save(credentials)
        return devices.map(\.name)
    }

    func listUnits() throws -> [NetHomeUnit] {
        guard let credentials = NetHomeKeychain.load() else {
            throw serviceError("Connect NetHome Plus in the Mac companion first.")
        }
        return try listUnits(credentials: credentials)
    }

    func signOut() {
        NetHomeKeychain.delete()
    }

    func perform(
        type: String,
        unit: String,
        text: String,
        value: Int,
        valueTenths: Int? = nil
    ) -> (succeeded: Bool, changed: Bool) {
        guard let credentials = NetHomeKeychain.load(), !unit.isEmpty else { return (false, false) }
        let arguments: [String]
        switch type {
        case "netHomePower":
            arguments = ["set", unit, "power", text]
        case "netHomeTemperature":
            let temperature = min(max(Double(valueTenths ?? value * 10) / 10, 16), 30)
            arguments = ["set", unit, "temperature", String(format: "%.1f", temperature)]
        case "netHomeMode":
            arguments = ["set", unit, "mode", text]
        case "netHomeFan":
            arguments = ["set", unit, "fan", String(min(max(value, 20), 100))]
        case "netHomeClimate":
            let temperature = min(max(Double(valueTenths ?? 220) / 10, 16), 30)
            arguments = [
                "set", unit, "climate", text,
                String(format: "%.1f", temperature),
                String(min(max(value, 20), 100)),
            ]
        default:
            return (false, false)
        }
        guard let response = try? runBridge(
            arguments: arguments,
            credentials: credentials
        ) else { return (false, false) }
        let succeeded = response["ok"] as? Bool == true
        return (succeeded, succeeded && (response["changed"] as? Bool ?? true))
    }

    private func runBridge(arguments: [String], credentials: NetHomeCredentials) throws -> [String: Any] {
        operationLock.lock()
        defer { operationLock.unlock() }
        try ensureDependency()
        guard let script = netHomeBridgeURL else {
            throw serviceError("The NetHome bridge resource is missing.")
        }
        let result = try runPython(
            arguments: [script.path] + arguments,
            credentials: credentials,
            captureOutput: true
        )
        guard let object = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any] else {
            let details = String(data: result.errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw serviceError(details?.isEmpty == false
                ? details!
                : "NetHome returned an invalid response.")
        }
        if result.status != 0 {
            throw serviceError(object["error"] as? String ?? "NetHome request failed.")
        }
        return object
    }

    private func listUnits(credentials: NetHomeCredentials) throws -> [NetHomeUnit] {
        let response = try runBridge(arguments: ["list"], credentials: credentials)
        guard response["ok"] as? Bool == true else {
            throw serviceError(response["error"] as? String ?? "NetHome login failed.")
        }
        return (response["devices"] as? [[String: Any]] ?? []).compactMap { device in
            guard let id = device["id"] as? String,
                  let name = device["name"] as? String else { return nil }
            return NetHomeUnit(id: id, name: name)
        }
    }

    private func ensureDependency() throws {
        let marker = pythonPackagesURL.appendingPathComponent("midea_beautiful/__init__.py")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try FileManager.default.createDirectory(at: pythonPackagesURL, withIntermediateDirectories: true)
        let result = try runPython(
            arguments: [
                "-m", "pip", "install", "--disable-pip-version-check", "--quiet",
                "--target", pythonPackagesURL.path,
                "midea-beautiful-air==\(Self.packageVersion)",
                "urllib3<2",
            ],
            credentials: nil,
            captureOutput: false
        )
        guard result.status == 0 else {
            throw serviceError("Could not install the bundled NetHome support library.")
        }
    }

    private var pythonPackagesURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("paperGIF Mac/Python", isDirectory: true)
    }

    private var netHomeBridgeURL: URL? {
        if let resources = Bundle.main.resourceURL,
           let appResources = Bundle(
               url: resources.appendingPathComponent("PaperGIFMac_PaperGIFMac.bundle")
           ),
           let script = appResources.url(forResource: "net_home_bridge", withExtension: "py") {
            return script
        }
        return Bundle.module.url(forResource: "net_home_bridge", withExtension: "py")
    }

    private func runPython(
        arguments: [String],
        credentials: NetHomeCredentials?,
        captureOutput: Bool
    ) throws -> (status: Int32, output: Data, errorOutput: Data) {
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = pythonPackagesURL.path
        if let credentials {
            environment["PAPERGIF_NETHOME_ACCOUNT"] = credentials.account
            environment["PAPERGIF_NETHOME_PASSWORD"] = credentials.password
        }
        let isInstallingPackages = arguments.starts(with: ["-m", "pip"])
        let result = try BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: arguments,
            environment: environment,
            captureOutput: captureOutput,
            timeout: isInstallingPackages ? 120 : 30
        )
        return (result.status, result.output, result.errorOutput)
    }

    private func serviceError(_ message: String) -> NSError {
        NSError(domain: "PaperGIFNetHome", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}