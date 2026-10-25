import Foundation

/// `~/.claude/settings.json` の `hooks` に notch-hook を登録・削除する（ROADMAP 1-7、ADR-0001）。
///
/// ここは JSON の変換だけを行い、ファイルの読み書きは `SafeFileWriter` が行う。
/// 自分のエントリは「`command` が `notch-hook` という名前の実行ファイル」で見分け、それ以外には触らない。
public enum HookInstaller {
    public static let executableName = "notch-hook"

    /// 登録する 1 件。
    public struct Registration: Sendable, Equatable {
        public var event: String
        public var matcher: String?
        public var arguments: [String]
        public var timeout: Int
    }

    /// 送るだけのイベント（ADR-0001 の表）。応答待ちの `--wait` / `--ask` は M2 で足す。
    /// `PermissionRequest` も M1 では送るだけ（承認待ちの表示に使う。何も出力しないので判断は Claude Code に任せる）。
    public static let sendOnlyEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
        "PostToolUseFailure", "Notification", "Stop", "StopFailure", "SubagentStart", "SubagentStop",
    ]

    public static let sendOnlyTimeout = 5

    public static var registrations: [Registration] {
        sendOnlyEvents.map { Registration(event: $0, matcher: nil, arguments: [], timeout: sendOnlyTimeout) }
    }

    public enum PlanError: Error, Equatable {
        /// 設定ファイルの最上位がオブジェクトでない。
        case settingsNotAnObject
        /// `hooks` がオブジェクトでない。
        case hooksNotAnObject
        /// `hooks.<イベント>` が配列でない。
        case eventNotAnArray(String)
    }

    /// 自分のエントリを（古いものも含めて）外してから、今の登録内容を足す。
    public static func install(into settings: OrderedJSON, hookPath: String) throws -> OrderedJSON {
        var result = try uninstall(from: settings)
        var hooks = result["hooks"] ?? .object([])
        for registration in registrations {
            var groups = hooks[registration.event]?.arrayValue ?? []
            var group: [OrderedJSON.Member] = []
            if let matcher = registration.matcher { group.append(.init("matcher", .string(matcher))) }
            group.append(.init("hooks", .array([handler(for: registration, hookPath: hookPath)])))
            groups.append(.object(group))
            hooks.set(registration.event, .array(groups))
        }
        result.set("hooks", hooks)
        return result
    }

    static func handler(for registration: Registration, hookPath: String) -> OrderedJSON {
        .object([
            .init("type", .string("command")),
            .init("command", .string(hookPath)),
            .init("args", .array(registration.arguments.map(OrderedJSON.string))),
            .init("timeout", .number(String(registration.timeout))),
        ])
    }

    /// 自分のエントリだけを外す。空になったグループ・イベント・`hooks` は（自分が空にした場合だけ）消す。
    public static func uninstall(from settings: OrderedJSON) throws -> OrderedJSON {
        guard settings.members != nil else { throw PlanError.settingsNotAnObject }
        guard let hooks = settings["hooks"] else { return settings }
        guard var events = hooks.members else { throw PlanError.hooksNotAnObject }

        var changed = false
        for (eventIndex, event) in events.enumerated().reversed() {
            guard let groups = event.value.arrayValue else { throw PlanError.eventNotAnArray(event.key) }
            var newGroups: [OrderedJSON] = []
            for group in groups {
                guard let handlers = group["hooks"]?.arrayValue else {
                    newGroups.append(group)
                    continue
                }
                let kept = handlers.filter { !isOurHandler($0) }
                if kept.count == handlers.count {
                    newGroups.append(group)
                } else {
                    changed = true
                    if !kept.isEmpty {
                        var newGroup = group
                        newGroup.set("hooks", .array(kept))
                        newGroups.append(newGroup)
                    }
                }
            }
            if newGroups.isEmpty && !groups.isEmpty {
                events.remove(at: eventIndex)
            } else {
                events[eventIndex].value = .array(newGroups)
            }
        }
        guard changed else { return settings }

        var result = settings
        result.set("hooks", events.isEmpty ? nil : .object(events))
        return result
    }

    /// `command` が notch-hook を指しているハンドラか。
    public static func isOurHandler(_ handler: OrderedJSON) -> Bool {
        guard let command = handler["command"]?.stringValue else { return false }
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        // 古い形式（シェル経由で引数付き、パスを引用符で囲む）も見分けられるように、最初の語も見る。
        let firstWord: String
        if let quote = trimmed.first, quote == "\"" || quote == "'" {
            firstWord = String(trimmed.dropFirst().prefix { $0 != quote })
        } else {
            firstWord = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        }
        return [trimmed, firstWord].contains { ($0 as NSString).lastPathComponent == executableName }
    }

    public enum Status: Sendable, Equatable {
        case notInstalled
        /// 自分のエントリはあるが、パスやイベントが今の登録内容と違う。
        case outdated
        case installed
    }

    /// 今の登録内容と比べる。他のフックの並び順は問わない。
    public static func status(of settings: OrderedJSON, hookPath: String) -> Status {
        guard let events = settings["hooks"]?.members else { return .notInstalled }
        var ours: [String: [OrderedJSON]] = [:]
        for event in events {
            for group in event.value.arrayValue ?? [] {
                for handler in group["hooks"]?.arrayValue ?? [] where isOurHandler(handler) {
                    ours[event.key, default: []].append(handler)
                }
            }
        }
        if ours.isEmpty { return .notInstalled }
        var expected: [String: [OrderedJSON]] = [:]
        for registration in registrations {
            expected[registration.event, default: []].append(handler(for: registration, hookPath: hookPath))
        }
        return ours == expected ? .installed : .outdated
    }
}
