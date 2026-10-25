# 効果音の設計

- 対象: REQUIREMENTS F0-6（効果音）、F0-8（おやすみモード）
- 参考: coucou の `NotchBuddy/Sources/App/SoundEngine.swift`（MIT）と、その呼び出し箇所（`IslandWindowController.swift`、`HookServer.swift`）

## coucou ではどうしているか
- `Resources/sounds/` の WAV（29 種類、計 3.8 MB）を起動時に読み込み、音ごとに `AVAudioPlayer` を 3 つずつ用意して重ねて鳴らせるようにしている。
- 鳴らす場面: ノッチの展開 `open` と縮小 `close`、通知の出現 `peek`、承認待ち `approval`、質問 `question`、完了 `finish`、エラー `error`、承認したとき `approve`、キャラクターをなでたとき `hover` / `love` など。
- ターミナルが前面にあるときは、完了・エラーの音を鳴らさない（自分で画面を見ているので）。
- 設定はオン／オフと音量のスライダー（既定 0.12）。`~/Library/Application Support/NotchBuddy/Sounds/` に同じ名前のファイルを置くと差し替えられる。
- **音そのものは `LICENSE-ASSETS.md` で All rights reserved** なので使わない。コード（仕組み）は MIT なので参考にしてよい。

## このアプリの方針
- **音はすべてオリジナル**。音声ファイルを持たず、`AgentKit` の `SoundSynthesizer` が正弦波と倍音から起動後に合成し、メモリ上の WAV を `AVAudioPlayer(data:)` で鳴らす。キャラクターを SwiftUI の描画で作っているのと同じ考え方で、権利がはっきりし、アプリも軽い。
- 音は短く（0.5 秒未満）、丸い音色（正弦波主体）にして、キャラクターの「もちもち」に合わせる。
- 待機中の CPU 0 % を守るため、オーディオエンジンを動かし続けない。音ごとの `AVAudioPlayer` は初めて鳴らすときに作る。
- 承認などの操作が音のせいで遅れたり、音のせいで勝手に起きたりすることはない（音は表示の変化に付いていくだけ）。

## 鳴らす場面
| 音 | `SoundCue` | 鳴らすとき | 分類 | 状態 |
| --- | --- | --- | --- | --- |
| ぽわん（上がる） | `expand` | ノッチが展開した | 開閉 | 実装済み |
| ぽわん（下がる、小さめ） | `collapse` | 展開から縮んだ | 開閉 | 実装済み |
| ピコン | `notice` | お知らせ（peek）が出た | お知らせ | 実装済み |
| 上がる 3 音 | `approval` | 権限リクエストが届いた | お知らせ | 音のみ用意、M2-2 で使う |
| 「ん？」 | `question` | `AskUserQuestion` で回答を求められた | お知らせ | 音のみ用意、M2-3 で使う |
| ド・ミ・ソ・ド | `finished` | キャラクターが「完了」になった | お知らせ | 実装済み（M1-6 で hooks とつながる） |
| 下がる 2 音 | `error` | キャラクターが「エラー」になった | お知らせ | 実装済み（M1-6 で hooks とつながる） |

- 「承認待ち」の表情になっただけでは鳴らさない。peek の `notice`、または M2 の承認キューが `approval` を鳴らすので、同じ出来事で 2 回鳴らないようにする。
- M2 で承認待ちの peek を出すときは、`notice` の代わりに `approval` / `question` を鳴らす。
- お知らせが消えるとき、承認したときは鳴らさない（鳴る回数を増やしすぎない）。coucou の `approve` / `hover` / `love` に当たる音は、使ってみて欲しくなったら足す。

対応関係は `SoundCue.forPresentationChange(from:to:)` と `SoundCue.forMoodChange(from:to:)` にまとめ、`swift test` で確認している。

## 鳴らさない条件（`SoundGate`）
上から順に判定し、どれかに当たれば鳴らさない。
1. 「音を鳴らす」がオフ。
2. おやすみモード中（`quietUntil` より前）。時刻を過ぎれば自動で解除される（タイマーは使わない）。
3. 分類ごとのスイッチ（「ノッチの開閉の音」「お知らせの音」）がオフ。
4. 開閉の音だけ: macOS の「ユーザインターフェイスのサウンドエフェクトを再生」（`com.apple.systemsound` の `com.apple.sound.uiaudio.enabled`）がオフ。
5. 同じ音を 0.25 秒以内に続けて鳴らそうとした（マウスの出入りが速いとき）。

## 設定（当面はメニューバーの「サウンド」メニュー、M5 で設定画面へ）
| 項目 | 既定 | 内容 |
| --- | --- | --- |
| 音を鳴らす | オン | すべての音 |
| 音量 | 中 | 小 0.3 / 中 0.6 / 大 1.0（システムの音量に対する割合） |
| ノッチの開閉の音 | オン | `expand` / `collapse` |
| お知らせの音 | オン | `notice` / `approval` / `question` / `finished` / `error` |
| おやすみモード | オフ | 「1 時間」「明日の朝 8 時まで」。音だけを止め、peek などの表示はそのまま |
| 音を試す | — | 設定にかかわらず各音を鳴らす（音量は設定どおり） |

保存先は UserDefaults の `soundSettings`（`SoundSettings` の JSON）。

## 後回しにしたこと
- **macOS の集中モード（おやすみモード）との連動**: 状態を読むには `INFocusStatusCenter` と「集中モードの状態」の entitlement・許可ダイアログが要る。署名を整える M5 で検討する。それまではアプリ自身のおやすみモードを使う。
- **ターミナルが前面のときに完了・エラーの音を鳴らさない**（coucou の挙動）: どのセッションがどのターミナルかを知る必要があるので、M1-6 のセッション一覧と一緒に入れる。
- **自分の音に差し替える**: coucou のように Application Support のフォルダに置いた音声ファイルで差し替えられるようにする。需要があれば M5。
