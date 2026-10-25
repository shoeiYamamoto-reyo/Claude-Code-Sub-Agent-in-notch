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
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(timeoutMilliseconds)
        func remaining() -> Int {
            let left = clock.now.duration(to: deadline)
            return max(0, Int(left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000))
        }

        guard let address = UnixSocket.address(for: path) else { return false }
        let fd = socket(AF_UNIX, UnixSocket.streamType, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        UnixSocket.disableSigpipe(fd)
        guard UnixSocket.setNonBlocking(fd) else { return false }

        let connected = UnixSocket.withSockaddr(address) { connect(fd, $0, $1) }
        if connected != 0 {
            // EAGAIN（相手の受付待ちが一杯）や ECONNREFUSED・ENOENT は待たずに諦める。
            guard errno == EINPROGRESS, UnixSocket.waitWritable(fd, milliseconds: remaining()) else { return false }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return false }
        }

        return data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = Foundation.send(fd, base + offset, buffer.count - offset, UnixSocket.sendFlags)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    guard UnixSocket.waitWritable(fd, milliseconds: remaining()) else { return false }
                } else {
                    return false
                }
            }
            return true
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
