import CoreServices
import Foundation

/// フォルダの中身が変わったら知らせる（ROADMAP 4-2）。FSEvents を使うので、変化が無い間は CPU を使わない。
///
/// サブフォルダも見張る。続けて起きた変更は `latency` 秒ごとにまとめて 1 回だけ知らせる。
/// コールバックに自分を unretained で渡すので、持ち主（`AgentLibrary`）と同じくアプリが終わるまで生かしておく。
@MainActor
final class DirectoryWatcher {
    private let latency: CFTimeInterval
    private let onChange: @MainActor () -> Void
    private var stream: FSEventStreamRef?
    private(set) var paths: [String] = []

    init(latency: CFTimeInterval = 0.5, onChange: @escaping @MainActor () -> Void) {
        self.latency = latency
        self.onChange = onChange
    }

    /// 見張るフォルダを差し替える。前と同じなら何もしない。
    func watch(_ paths: [String]) {
        let paths = paths.sorted()
        guard paths != self.paths else { return }
        stop()
        self.paths = paths
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            directoryWatcherCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        paths = []
    }

    fileprivate func notify() {
        onChange()
    }
}

/// FSEvents のコールバック（C の関数ポインタなので、何も捕まえないグローバル関数にする）。
/// メインキューで呼ばれるよう `FSEventStreamSetDispatchQueue` で指定してある。
private func directoryWatcherCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ count: Int,
    _ paths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
    MainActor.assumeIsolated {
        watcher.notify()
    }
}
