/// notch-hook とアプリの間で共有する定数（ADR-0001）。
public enum HookBridge {
    /// ワイヤプロトコルのバージョン。中継 → アプリのメッセージの `v`。
    public static let protocolVersion = 1

    /// `~/Library/Application Support` の下に作るディレクトリ名。
    public static let supportDirectoryName = "NotchAgent"

    /// ソケットのファイル名。
    public static let socketFileName = "notch.sock"

    /// macOS の `sockaddr_un.sun_path` は終端の NUL を含めて 104 バイト。
    public static let maxSocketPathBytes = 103

    /// 中継 CLI がソケットへの接続を諦めるまでの時間（ミリ秒）。
    public static let connectTimeoutMilliseconds = 300

    /// 1 メッセージの上限。超えるものは中継 CLI が送らず、アプリも受け取らない。
    public static let maxMessageBytes = 1 << 20

    /// 環境変数でソケットのパスを差し替える（テストと開発用）。
    public static let socketPathEnvironmentKey = "NOTCH_AGENT_SOCKET"

    /// hook の環境からソケットのパスを決める。
    public static func socketPath(environment: [String: String]) -> String? {
        if let override = environment[socketPathEnvironmentKey], !override.isEmpty {
            return override
        }
        guard let home = environment["HOME"], !home.isEmpty else { return nil }
        return socketPath(home: home)
    }

    /// ホームディレクトリからソケットのパスを組み立てる。
    public static func socketPath(home: String) -> String {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return "\(base)/Library/Application Support/\(supportDirectoryName)/\(socketFileName)"
    }

    /// パスが `sun_path` に収まるか。収まらない場合、アプリはソケットを作らない。
    public static func fitsInSocketAddress(_ path: String) -> Bool {
        path.utf8.count <= maxSocketPathBytes
    }
}
