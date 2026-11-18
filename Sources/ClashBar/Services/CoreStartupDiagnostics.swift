import Foundation

/// 内核启动失败时的可读诊断：配置里声明的监听端口，当前被哪个进程占着。
///
/// 背景：`mixed-port` 被 ClashX / Surge / 另一个 mihomo 占用时，mihomo 只会往 stderr 写
/// `bind: address already in use`，App 弹窗只说"启动失败"。把这一层翻译成人话，能省掉
/// 用户翻日志的时间。
struct CorePortConflict: Sendable {
    let port: Int
    let pid: Int32
    let processName: String
}

enum CoreStartupDiagnostics {
    /// 只看 mihomo 需要 bind 的顶层键。`dns.listen` 等嵌套键不扫，避免误报。
    private static let declaredPortKeys: Set<String> = [
        "mixed-port",
        "port",
        "socks-port",
        "redir-port",
        "tproxy-port",
    ]

    /// 同步实现，调用方应放到后台任务里跑（`lsof` 通常几十毫秒，但不应占主线程）。
    static func portConflicts(configPath: String) -> [CorePortConflict] {
        let ports = self.declaredPorts(configPath: configPath)
        guard !ports.isEmpty else { return [] }
        return ports.compactMap { port in
            guard let holder = self.listeningProcess(port: port) else { return nil }
            return CorePortConflict(port: port, pid: holder.pid, processName: holder.name)
        }
    }

    // MARK: - 配置解析

    /// 极简 YAML 顶层扫描：足够覆盖 `mixed-port: 7890` / `mixed-port: 7890 # 注释` 这类写法，
    /// 不引入完整 YAML 解析器。
    private static func declaredPorts(configPath: String) -> [Int] {
        guard let data = FileManager.default.contents(atPath: configPath),
              let text = String(data: data, encoding: .utf8)
        else {
            return []
        }

        var ports: Set<Int> = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // 缩进的行属于子节点，端口键只会出现在顶层。
            guard !rawLine.hasPrefix(" "), !rawLine.hasPrefix("\t") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }

            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            guard self.declaredPortKeys.contains(key) else { continue }

            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let digits = value.prefix { $0.isNumber }
            guard let port = Int(digits), port > 0, port <= 65535 else { continue }
            ports.insert(port)
        }
        return ports.sorted()
    }

    // MARK: - 端口占用者

    private static func listeningProcess(port: Int) -> (pid: Int32, name: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        var pid: Int32?
        var name = ""
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("c") {
                name = String(line.dropFirst())
            }
        }
        guard let pid else { return nil }
        return (pid, name.isEmpty ? "unknown" : name)
    }
}
