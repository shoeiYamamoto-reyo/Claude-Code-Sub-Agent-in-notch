import AgentKit
import AppKit
import SwiftUI

/// ノッチのパネルを置き、マウスの位置から表示状態と目の向きを決める。
///
/// 待機中に CPU を使わないため、常時動くタイマーは持たない。
/// - マウスの位置はイベント（グローバル／ローカルのモニタとトラッキング領域）で受け、15 Hz 以下に間引く。
///   マウスが止まっていれば何もしない。
/// - 展開・縮小の遅延は、状態機械が返す時刻にワンショットで起きるだけ。
///
/// 表示状態とキャラクターの状態が変わったときの効果音もここで鳴らす（docs/design/sound.md）。
@MainActor
final class NotchPanelController {
    private static let displayChoiceKey = "displayChoice"
    /// マウス位置を処理する最短間隔（15 Hz）。
    private static let pointerInterval: Duration = .milliseconds(66)

    let model: NotchModel
    let sound = SoundPlayer()
    private let panel = NotchPanel.make()
    private let pointerTracker = PointerTracker()
    private var machine = NotchPresentationMachine()
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var deadlineTask: Task<Void, Never>?
    private var pointerTask: Task<Void, Never>?
    private var lastPointerUpdate = ContinuousClock.now - .seconds(1)
    /// この時刻までは peek の `notice` を鳴らさない（`playAlert` で代わりの音を鳴らした直後）。
    private var noticeSoundSuppressedUntil: Date?
    /// クイック入力の前に前面にあったアプリ。入力を終えたらキー入力を返す。
    private var appBeforeQuickInput: NSRunningApplication?

    init(model: NotchModel) {
        self.model = model
        if let raw = UserDefaults.standard.string(forKey: Self.displayChoiceKey),
           let choice = DisplayChoice(rawValue: raw) {
            model.displayChoice = choice
        }
    }

    func start() {
        let hostingView = FirstMouseHostingView(rootView: NotchRootView(model: model))
        hostingView.sizingOptions = []
        hostingView.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: pointerTracker,
            userInfo: nil
        ))
        panel.contentView = hostingView
        pointerTracker.onPointerEvent = { [weak self] in self?.pointerMoved() }

        // パネルがクリックを透過している間は他のアプリ宛てのイベントとして、
        // 受けている間は自分宛てのイベントとして届くので、両方を見る。
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            monitors.append(local)
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        })
        // ほかのアプリやウインドウを押してパネルがキーでなくなったら、入力を終える（縮むのはマウスが離れてから）。
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endQuickInput(collapse: false) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.processPointer() }
        })

        relayout()
    }

    // MARK: - 外からの操作

    func setMood(_ mood: CharacterMood) {
        if let cue = SoundCue.forMoodChange(from: model.mood, to: mood) {
            sound.play(cue)
        }
        model.mood = mood
        processPointer()
    }

    /// 承認待ち・質問などの知らせの音を鳴らす（docs/design/sound.md: peek の `notice` の代わりに鳴らす）。
    func playAlert(_ cue: SoundCue) {
        sound.play(cue)
        // 続く setMood / setNotice のどこで peek に切り替わっても、notice が重ならないようにする。
        noticeSoundSuppressedUntil = .now + 1
    }

    func setNotice(_ text: String?) {
        model.noticeText = text
        machine.setNotice(text != nil, at: .now)
        applyMachine()
    }

    func setDisplayChoice(_ choice: DisplayChoice) {
        model.displayChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: Self.displayChoiceKey)
        relayout()
    }

    // MARK: - クイック入力（ROADMAP 3-5）

    /// ノッチを展開したまま留め、パネルでキー入力を受ける（入力欄を押したとき・ショートカット）。
    func beginQuickInput() {
        guard model.layout != nil else { return }
        if !model.isQuickInputActive {
            let front = NSWorkspace.shared.frontmostApplication
            appBeforeQuickInput = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        }
        model.isQuickInputActive = true
        panel.acceptsKeyInput = true
        machine.pin()
        applyMachine()
        // 操作しないパネルなので、アプリを前面に出さずにキー入力だけを受ける。
        panel.makeKeyAndOrderFront(nil)
    }

    /// 入力を終える。`collapse` ならすぐ縮める（Esc・開始したあと）。
    func endQuickInput(collapse: Bool) {
        guard model.isQuickInputActive else { return }
        model.isQuickInputActive = false
        panel.acceptsKeyInput = false
        if collapse {
            machine.collapse()
        } else {
            machine.unpin(at: .now)
        }
        if panel.isKeyWindow {
            panel.resignKey()
            appBeforeQuickInput?.activate()
        }
        appBeforeQuickInput = nil
        processPointer()
    }

    // MARK: - 配置

    private func relayout() {
        let screens = NSScreen.screens
        let metrics = screens.map(ScreenMetrics.init(screen:))
        guard let index = model.displayChoice.screenIndex(in: metrics) else {
            model.layout = nil
            panel.orderOut(nil)
            return
        }
        let layout = NotchLayout(geometry: NotchGeometry(screen: metrics[index]))
        model.layout = layout
        panel.setFrame(layout.panelFrame, display: true)
        panel.orderFrontRegardless()
        processPointer()
    }

    // MARK: - マウス

    private func pointerMoved() {
        guard pointerTask == nil else { return }
        let elapsed = ContinuousClock.now - lastPointerUpdate
        if elapsed >= Self.pointerInterval {
            processPointer()
            return
        }
        let wait = Self.pointerInterval - elapsed
        pointerTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard let self else { return }
            self.pointerTask = nil
            self.processPointer()
        }
    }

    private func processPointer() {
        lastPointerUpdate = .now
        guard let layout = model.layout else { return }
        let location = NSEvent.mouseLocation

        if layout.hoverFrame(for: machine.state).contains(location) {
            machine.mouseEntered(at: .now)
        } else {
            machine.mouseExited(at: .now)
        }
        applyMachine()
        updateEyes(layout: layout, cursor: location)
    }

    private func updateEyes(layout: NotchLayout, cursor: CGPoint) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard model.mood == .idle && !reduceMotion else {
            // 待機中以外は目を中央に戻す（補間しない）。
            if model.eyeMotion != .resting(at: .zero) { model.eyeMotion = .resting(at: .zero) }
            return
        }
        let target = EyeTracking.offset(eyeCenter: layout.eyeCenter, cursor: cursor)
        guard EyeTracking.needsRedraw(from: model.eyeMotion.to, to: target) else { return }
        model.eyeMotion = model.eyeMotion.retargeted(to: target, at: Date.now.timeIntervalSinceReferenceDate)
    }

    // MARK: - 状態機械

    private func applyMachine() {
        if model.presentation != machine.state {
            if let cue = SoundCue.forPresentationChange(from: model.presentation, to: machine.state),
               !(cue == .notice && (noticeSoundSuppressedUntil.map { $0 > .now } ?? false)) {
                sound.play(cue)
            }
            model.presentation = machine.state
        }
        if let layout = model.layout {
            let hovering = layout.hoverFrame(for: machine.state).contains(NSEvent.mouseLocation)
            panel.ignoresMouseEvents = !hovering
        }

        deadlineTask?.cancel()
        deadlineTask = nil
        guard let deadline = machine.nextDeadline else { return }
        let delay = max(0, deadline.timeIntervalSinceNow)
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.machine.tick(at: .now)
            // 展開・縮小で島の大きさが変わったので、今の位置で判定し直す（applyMachine も呼ばれる）。
            self.processPointer()
        }
    }
}

/// 前面にないパネルでも、最初のクリックでボタンが押せるようにする（承認カードのボタン）。
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// トラッキング領域の受け手。パネルがクリックを受けている間のマウス移動を拾う。
private final class PointerTracker: NSResponder {
    var onPointerEvent: (() -> Void)?

    override func mouseMoved(with event: NSEvent) { onPointerEvent?() }
    override func mouseEntered(with event: NSEvent) { onPointerEvent?() }
    override func mouseExited(with event: NSEvent) { onPointerEvent?() }
}

extension ScreenMetrics {
    init(screen: NSScreen) {
        self.init(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryTopRightWidth: screen.auxiliaryTopRightArea?.width
        )
    }
}
