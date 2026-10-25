import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// アプリ側のソケット受信（ADR-0001）。中継 CLI からの 1 行を受け取り、呼び出し側に渡す。
///
/// - 1 接続 1 メッセージ。`event` は行を読んだら閉じる。
/// - `wait` / `ask`（応答待ち）は接続を開いたまま `onRequest` に渡し、`reply(_:to:)` で 1 行返して閉じる。
///   相手が先に閉じた（ターミナルで答えた・Claude Code が hook を止めた）とき、またはアプリ側の諦め時間
///   （115 / 125 秒）を過ぎたときは、応答せずに閉じて `onClosed` を呼ぶ。
/// - 状態はすべて内部の直列キューで扱う。コールバックもそのキューで呼ばれる。
/// - fd を閉じるのは読み取りソースの cancel handler だけ（二重 close を防ぐ）。
/// - イベントが無いあいだは何も動かない（タイマーなし）。
public final class HookSocketServer: @unchecked Sendable {
    public enum StartError: Error, Equatable {
        case pathTooLong
        case alreadyRunning
        case system(call: String, errno: Int32)
    }

    public typealias MessageHandler = @Sendable (HookWireMessage) -> Void
    public typealias RequestHandler = @Sendable (_ id: Int, _ message: HookWireMessage) -> Void
    public typealias ClosedHandler = @Sendable (_ id: Int) -> Void

    public static let maxClients = 32
    public static let readTimeout: DispatchTimeInterval = .seconds(5)

    public let path: String
    private let onMessage: MessageHandler
    private let onRequest: RequestHandler?
    private let onClosed: ClosedHandler?
    private let waitGiveUp: TimeInterval
    private let askGiveUp: TimeInterval
    private let queue = DispatchQueue(label: "dev.notchagent.HookSocketServer")
    private var listenSource: DispatchSourceRead?
    private var clients: [Int: Client] = [:]
    private var nextClientID = 0

    private final class Client {
        let source: DispatchSourceRead
        let fd: Int32
        var buffer = Data()
        /// 行を受け取り済み。
        var delivered = false
        /// 応答待ちとして呼び出し側に渡した。
        var pending = false
        init(source: DispatchSourceRead, fd: Int32) {
            self.source = source
            self.fd = fd
        }
    }

    /// - Parameters:
    ///   - onMessage: `event` のメッセージ。`onRequest` が nil なら、`wait` / `ask` もここに渡して応答せずに閉じる。
    ///   - onRequest: `wait` / `ask` のメッセージ。必ず `reply(_:to:)` か `cancel(_:)` を呼ぶか、`onClosed` を待つ。
    ///   - onClosed: 応答待ちの接続が、応答しないまま閉じた。
    public init(
        path: String,
        waitGiveUp: TimeInterval = HookBridge.waitGiveUpSeconds,
        askGiveUp: TimeInterval = HookBridge.askGiveUpSeconds,
        onMessage: @escaping MessageHandler,
        onRequest: RequestHandler? = nil,
        onClosed: ClosedHandler? = nil
    ) {
        self.path = path
        self.waitGiveUp = waitGiveUp
        self.askGiveUp = askGiveUp
        self.onMessage = onMessage
        self.onRequest = onRequest
        self.onClosed = onClosed
    }

    /// 応答待ちの接続に 1 行返して閉じる。もう閉じていれば何もしない（false）。
    @discardableResult
    public func reply(_ reply: HookReply, to id: Int) -> Bool {
        guard let line = try? reply.encodedLine() else { return false }
        return queue.sync {
            guard let client = clients[id], client.pending else { return false }
            let written = line.withUnsafeBytes { buffer in
                UnixSocket.write(client.fd, buffer.baseAddress!, buffer.count)
            }
            finish(clientID: id, notify: false)
            return written == line.count
        }
    }

    /// 応答待ちの接続を、応答せずに閉じる（中継は何も出力せず、ターミナルの確認に任せる）。
    public func cancel(_ id: Int) {
        queue.sync { finish(clientID: id, notify: false) }
    }

    deinit {
        listenSource?.cancel()
        for client in clients.values { client.source.cancel() }
    }

    /// ソケットを作って待ち受けを始める。古いソケットファイルが残っていれば消す。
    public func start() throws {
        guard HookBridge.fitsInSocketAddress(path), let address = UnixSocket.address(for: path) else {
            throw StartError.pathTooLong
        }
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw StartError.system(call: "mkdir", errno: 0)
        }
        chmod(directory, 0o700)

        if FileManager.default.fileExists(atPath: path) {
            if UnixSocketClient.isListening(at: path) { throw StartError.alreadyRunning }
            unlink(path)
        }

        let fd = socket(AF_UNIX, UnixSocket.streamType, 0)
        guard fd >= 0 else { throw StartError.system(call: "socket", errno: errno) }
        guard UnixSocket.withSockaddr(address, { bind(fd, $0, $1) }) == 0 else {
            let code = errno
            close(fd)
            throw StartError.system(call: "bind", errno: code)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0, UnixSocket.setNonBlocking(fd) else {
            let code = errno
            close(fd)
            unlink(path)
            throw StartError.system(call: "listen", errno: code)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(listenFD: fd) }
        source.setCancelHandler { close(fd) }
        queue.sync { listenSource = source }
        source.resume()
    }

    /// 待ち受けをやめ、開いている接続を閉じ、ソケットファイルを消す。
    public func stop() {
        queue.sync {
            listenSource?.cancel()
            listenSource = nil
            for client in clients.values { client.source.cancel() }
            clients.removeAll()
        }
        unlink(path)
    }

    // MARK: - 以下は queue の上だけで動く

    private func acceptPending(listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return  // EAGAIN: 今は待っている接続が無い
            }
            guard clients.count < Self.maxClients, UnixSocket.setNonBlocking(fd) else {
                close(fd)
                continue
            }
            UnixSocket.disableSigpipe(fd)
            let id = nextClientID
            nextClientID += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable(clientID: id) }
            source.setCancelHandler { close(fd) }
            clients[id] = Client(source: source, fd: fd)
            source.resume()
            // 送りかけで止まった相手をいつまでも抱えない（応答待ちに入った接続は別の時間で諦める）。
            queue.asyncAfter(deadline: .now() + Self.readTimeout) { [weak self] in
                guard let self, let client = self.clients[id], !client.delivered else { return }
                self.finish(clientID: id, notify: false)
            }
        }
    }

    private func readAvailable(clientID: Int) {
        guard let client = clients[clientID] else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(client.fd, $0.baseAddress, $0.count) }
            if count > 0 {
                // 応答待ちの間に届いた余計なデータは読み捨てる。
                guard !client.delivered else { continue }
                client.buffer.append(contentsOf: chunk[0..<count])
                if let newline = client.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    deliver(client.buffer[client.buffer.startIndex..<newline], clientID: clientID)
                    return
                }
                if client.buffer.count > HookBridge.maxMessageBytes {
                    finish(clientID: clientID, notify: false)
                    return
                }
            } else if count == 0 {
                if client.delivered {
                    // 応答を待っている間に相手が閉じた。
                    finish(clientID: clientID, notify: true)
                } else {
                    // 改行なしで閉じられても、そこまでを 1 行として扱う（相手はもう応答を読めない）。
                    if let message = decode(client.buffer) { onMessage(message) }
                    finish(clientID: clientID, notify: false)
                }
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                finish(clientID: clientID, notify: true)
                return
            }
        }
    }

    private func deliver(_ line: Data, clientID: Int) {
        guard let client = clients[clientID] else { return }
        client.delivered = true
        client.buffer = Data()
        guard let message = decode(line) else {
            finish(clientID: clientID, notify: false)
            return
        }
        guard message.mode != .event, let onRequest else {
            onMessage(message)
            finish(clientID: clientID, notify: false)
            return
        }
        client.pending = true
        let giveUp = message.mode == .wait ? waitGiveUp : askGiveUp
        queue.asyncAfter(deadline: .now() + giveUp) { [weak self] in
            self?.finish(clientID: clientID, notify: true)
        }
        onRequest(clientID, message)
    }

    private func decode(_ line: Data) -> HookWireMessage? {
        guard !line.isEmpty,
              let message = try? HookWireMessage.decode(line: Data(line)),
              message.v == HookBridge.protocolVersion
        else { return nil }
        return message
    }

    private func finish(clientID: Int, notify: Bool) {
        guard let client = clients.removeValue(forKey: clientID) else { return }
        client.source.cancel()
        if notify && client.pending { onClosed?(clientID) }
    }
}
