import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Unix ドメインソケットの低水準の処理。中継 CLI（送信側）とアプリ（受信側）で共有する。
enum UnixSocket {
    #if canImport(Darwin)
    static let streamType = SOCK_STREAM
    #else
    static let streamType = Int32(SOCK_STREAM.rawValue)
    #endif

    /// `sockaddr_un` を作る。パスが `sun_path` に収まらなければ nil。
    static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return address
    }

    static func withSockaddr<T>(_ address: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var address = address
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func setNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    /// 切れた相手に書いても SIGPIPE でプロセスが落ちないようにする（macOS はソケット単位で指定する）。
    static func disableSigpipe(_ fd: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    static var sendFlags: Int32 {
        #if canImport(Darwin)
        0
        #else
        Int32(MSG_NOSIGNAL)
        #endif
    }

    /// `send(2)`。`UnixSocketClient.send` と名前がぶつかるので包む。
    static func write(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.send(fd, pointer, count, sendFlags)
        #else
        Glibc.send(fd, pointer, count, sendFlags)
        #endif
    }

    /// fd が読み込み可能（または相手が閉じた）になるまで最大 `milliseconds` 待つ。
    static func waitReadable(_ fd: Int32, milliseconds: Int) -> Bool {
        guard milliseconds > 0 else { return false }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let result = poll(&descriptor, 1, Int32(min(milliseconds, Int(Int32.max))))
            if result < 0 && errno == EINTR { continue }
            return result > 0
        }
    }

    /// fd が書き込み可能になるまで最大 `milliseconds` 待つ。
    static func waitWritable(_ fd: Int32, milliseconds: Int) -> Bool {
        guard milliseconds > 0 else { return false }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        while true {
            let result = poll(&descriptor, 1, Int32(milliseconds))
            if result < 0 && errno == EINTR { continue }
            return result > 0 && descriptor.revents & Int16(POLLOUT) != 0
        }
    }
}

/// 中継 CLI 側。接続して送るだけ（応答は待たない）。
public enum UnixSocketClient {
    /// `data` を送る。成功したら true。どんな失敗でも、おおむね `timeoutMilliseconds` 以内に戻る。
    /// ソケットが無い・誰も待っていない場合は即座に false を返す。
    public static func send(_ data: Data, to path: String, timeoutMilliseconds: Int) -> Bool {
        let deadline = Deadline(milliseconds: timeoutMilliseconds)
        guard let fd = connectAndSend(data, to: path, deadline: deadline) else { return false }
        close(fd)
        return true
    }

    /// `data` を送り、相手が返す 1 行（改行は含まない）を待つ（承認の応答待ち、ROADMAP 2-1）。
    /// 接続・送信は `connectTimeoutMilliseconds`、応答は `responseTimeoutMilliseconds` まで待つ。
    /// 接続できない・相手が何も返さずに閉じた・時間切れ・行が長すぎるときは nil。
    public static func exchange(
        _ data: Data,
        with path: String,
        connectTimeoutMilliseconds: Int,
        responseTimeoutMilliseconds: Int,
        maxResponseBytes: Int = HookBridge.maxMessageBytes
    ) -> Data? {
        guard let fd = connectAndSend(data, to: path, deadline: Deadline(milliseconds: connectTimeoutMilliseconds)) else {
            return nil
        }
        defer { close(fd) }
        let deadline = Deadline(milliseconds: responseTimeoutMilliseconds)
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            guard UnixSocket.waitReadable(fd, milliseconds: deadline.remaining()) else { return nil }
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                response.append(contentsOf: chunk[0..<count])
                if let newline = response.firstIndex(of: UInt8(ascii: "\n")) {
                    return Data(response[response.startIndex..<newline])
                }
                guard response.count <= maxResponseBytes else { return nil }
            } else if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                continue
            } else {
                return nil  // 何も返さずに閉じられた
            }
        }
    }

    /// 接続して全部書く。成功したら fd（呼び出し側が閉じる）。
    private static func connectAndSend(_ data: Data, to path: String, deadline: Deadline) -> Int32? {
        guard let address = UnixSocket.address(for: path) else { return nil }
        let fd = socket(AF_UNIX, UnixSocket.streamType, 0)
        guard fd >= 0 else { return nil }
        UnixSocket.disableSigpipe(fd)
        guard UnixSocket.setNonBlocking(fd) else {
            close(fd)
            return nil
        }

        let connected = UnixSocket.withSockaddr(address) { connect(fd, $0, $1) }
        if connected != 0 {
            // EAGAIN（相手の受付待ちが一杯）や ECONNREFUSED・ENOENT は待たずに諦める。
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard errno == EINPROGRESS, UnixSocket.waitWritable(fd, milliseconds: deadline.remaining()),
                  getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0
            else {
                close(fd)
                return nil
            }
        }

        let written = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let count = UnixSocket.write(fd, base + offset, buffer.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    guard UnixSocket.waitWritable(fd, milliseconds: deadline.remaining()) else { return false }
                } else {
                    return false
                }
            }
            return true
        }
        guard written else {
            close(fd)
            return nil
        }
        return fd
    }

    private struct Deadline {
        let clock = ContinuousClock()
        let end: ContinuousClock.Instant

        init(milliseconds: Int) {
            end = clock.now + .milliseconds(milliseconds)
        }

        func remaining() -> Int {
            let left = clock.now.duration(to: end)
            return max(0, Int(left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000))
        }
    }

    /// 誰かがそのパスで接続を待っているか（アプリの二重起動の確認用）。
    public static func isListening(at path: String) -> Bool {
        guard let address = UnixSocket.address(for: path) else { return false }
        let fd = socket(AF_UNIX, UnixSocket.streamType, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return UnixSocket.withSockaddr(address) { connect(fd, $0, $1) } == 0
    }
}
