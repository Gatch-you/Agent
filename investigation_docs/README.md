# Voice Loop Lab

設計書 **§12 実装順序 ステップ1（音声ループ単体の検証）** と
**§09 検証ステップ3（Kokoro の実機実測）** を1つのプロトタイプで回収するための検証用アプリ。

## これで何を確かめるのか

| # | 検証項目 | 結果 |
|---|---|---|
| 1 | **AEC（エコーキャンセル）が効くか** | ✅ **確認済み(2026-09-21)**。barge-in が実際の会話ループ中に繰り返し検出された |
| 2 | **barge-in が成立するか** | ✅ **確認済み(2026-09-21)**。項目1と同時に確認 |
| 3 | SpeechAnalyzer がマイク入力で動くか | ✅ **決定・確認済み**。`SpeechTranscriber`(新API)は不採用、`DictationTranscriber`(旧API系統)を採用。当初「日本リージョンで英語が使えない」と結論したが誤りで、正しくは「端末に未インストールのロケールは新規ダウンロードが進まない」不具合(言語・地域とは無関係)。fr-FR で追試したところ`DictationTranscriber`でも同じ新規ダウンロード不具合を確認したため、この不具合自体は解決していない。ただし本アプリは個人利用限定であり、使用する端末(この iPhone)には英語(en-US)アセットが既にインストール済みであることを実機確認済み(自己診断・実際のマイク入力の両方で認識成功)なので、この制約は個人利用のスコープでは問題にならない。**結論：STTは`DictationTranscriber`(オンデバイス・無料)を採用、Deepgram等クラウドSTTは不要**(設計書 §13) |
| 4 | **Kokoro の実機 RTF・メモリ・ウォームアップ** | ✅ **確認済み(2026-09-22)**。実機会話ループで5回合成した実測値: ウォームアップ込みロード **0.86 s**、RTF 平均 **0.153**（最悪 0.188）、ピークメモリ **687 MB**。§04判定基準（RTF平均<0.2、ウォームアップ<10s）は合格。ピークメモリは合格ライン(600MB)と要検討ライン(900MB)の中間で、要監視だが致命的ではない |

**LLM は繋いでいない。** ここで潰したいリスクは音声の往復であって応答生成ではないため、
`thinking` は定型応答で代替してある。検証を決定論的にするための意図的な設計。

---

## セットアップ

```bash
brew install xcodegen          # 未導入なら
cd voice-loop-lab
xcodegen generate
open VoiceLoopLab.xcodeproj
```

Xcode で以下を設定してから実機に転送する。

1. **Signing & Capabilities** → Team を自分の Apple ID に設定
2. **実機必須**（シミュレータではマイクの AEC が本来の挙動にならない）
3. Kokoro の重み（実測 **約318MB**、`config.json`込みで74ファイル）は `Resources/KokoroModel` としてビルド時にアプリへ同梱済み。初回起動時の HuggingFace への追加ダウンロードは発生しない（オフラインロード）
4. SpeechAnalyzer の音声認識モデルも初回に取得されることがある

XcodeGen を使いたくない場合は、Xcode で空の iOS App を作り `Sources/` 以下を追加、
SPM で `https://github.com/soniqo/speech-swift`（branch: main）を追加して
`KokoroTTS` と `AudioCommon` をリンクし、`project.yml` の `info:` にある
Info.plist キー4つを手で設定すれば同じになる。

---

## 実行手順

### ステップ1：AEC 検証（最優先）

1. 「開始」→ 状態が `listening` になるまで待つ（初回はモデル取得で数分）
2. **静かな部屋で、端末をスピーカー再生のまま机に置く**
3. 「AEC 検証」を押す → **何も喋らずに最後まで待つ**
4. 「計測」欄の判定を読む

```
無音 -58.3 dB → 再生中 -54.1 dB（差 4.2 dB）… AEC 有効
```

**判定基準**：差が **12 dB 未満**なら AEC が効いている。
20 dB 以上あれば自分の TTS をマイクで拾っており、そのままでは barge-in が誤爆する。

> 差が大きかった場合に試すこと
> - イヤホンを外す／Bluetooth を切る（ルート変更で voice processing が外れることがある）
> - 「Voice Processing: 有効」と表示されているか確認する
> - 音量を下げて再測定（AEC には処理できる音圧に上限がある）
> - それでもダメなら、`speech-swift` の `LocalVQEEchoCanceller`（ソフトウェア AEC）を
>   後段に足す構成を検討する

### ステップ2：会話ループと barge-in

1. 状態が `listening` の状態で英語で話しかける
2. 認識結果が確定すると定型応答が合成・再生される（`speaking`）
3. **再生中に割り込んで話す** → ログに `barge-in 検出` が出て即座に止まれば成功

### ステップ3：Kokoro のベンチ

会話を10往復ほど回してから「計測」欄を読む。

```
ウォームアップ含むロード: 4.82 s
合成回数: 12
RTF 平均: 0.094 / 最悪: 0.131
ピークメモリ: 412 MB
```

**判定の目安**（iPhone 16 Pro の公称値 RTF 0.08 が基準）

| 指標 | 合格 | 要検討 |
|---|---|---|
| RTF 平均 | < 0.2 | > 0.4 |
| ピークメモリ | < 600 MB | > 900 MB（jetsam のリスク） |
| ウォームアップ | < 10 s | > 20 s |

RTF が 1.0 を超えるとリアルタイム合成が破綻するので、その場合はフェーズ1.5 を見送る。

---

## 既知の落とし穴

### ANE コンパイラの不具合

soniqo/speech-swift の公式ドキュメントに記載がある通り、
**一部の iOS 26 ビルドでは ANE がこのモデルで不正な出力を出す**。
合成音がノイズや無音になる場合は `TtsEngine.load(bypassANE: true)` を試す。
（`KokoroTTSModel.fromPretrained(computeUnits: .cpuAndGPU)` になる）

### Voice Processing の有効化タイミング

`setVoiceProcessingEnabled(true)` は **`engine.start()` の前、タップを張る前**に
呼ばなければならない。また**有効化すると入力フォーマットが変わる**ため、
`inputNode.outputFormat(forBus:)` は必ず有効化の「後」に読む。
`AudioEngineHost.start()` がこの順序になっている。

### SpeechAnalyzer 周りの3つの罠

1. **リサンプリングしてくれない** — マイクと `bestAvailableAudioFormat` が違えば
   `AVAudioConverter` が必須。変換失敗を黙って捨てると「録れているのに文字が出ない」状態になる
2. **タップのバッファは再利用される** — 別スレッドへ渡す前にコピーを取る
   （`AVAudioPCMBuffer.deepCopy()` を用意してある）
3. **volatile 結果は置換であって追記ではない** — 追記すると単語が重複する

### 停止順序

タップ停止 → `continuation.finish()` → `finalizeAndFinishThroughEndOfInput()` →
結果 consumer の完了を待つ。consumer を先に殺すと最後の単語が消える。

### `-autoStart` 直後はマイクが機能しないことがある（2026-09-22）

アプリ起動直後、起動引数の `-autoStart YES`（`App.swift`の`.task`内）経由で
`startSession()`を呼ぶと、マイク入力が拾えない（`listening`にはなるが認識が進まない）
現象を実機で確認した。**画面の「停止」→「開始」を手動で一度押すと直る。**
`.task`がビュー読み込み中の早いタイミングで発火し、`AVAudioSession`が完全に
アクティブ化しきる前にマイクを掴みに行っているためと推測される（未確定）。
本番の`sessionMachine`では、セッション開始をアプリのシーンが`.active`に
なったことを確認してから行うガードが必要になりそうな知見。

### barge-in がTTS再生直後に誤発火することがある（2026-09-22）

AEC自体は実機で有効（§上記の判定参照）だが、セッション再開直後の数往復では
再生開始からほぼ即座に「barge-in 検出 → 再生を中断」が発火し、応答の音声が
最後まで聞こえないことがあった。5回目の合成では誤発火せず、AEC判定も
「差4.6dB…AEC有効」で正常だったため、恒常的な不具合ではなく、
セッション再開直後の数秒間（`silenceRMSdB`の基準値がまだ実環境に
馴染んでいない/AECのウォームアップ中）に限った過敏さと見られる。
本番では、セッション開始直後の数百ms〜数秒はbarge-in判定を無効化する
猶予期間を設けるなど、閾値・タイミングのチューニングが要る。

---

## ファイル構成

```
voice-agent-architecture.html   設計書本体（§01〜§14。このREADMEが参照する「設計書」）
kokoro_tts_listening_test.ipynb Kokoro 試聴テスト（検証ステップ1）。合格・採用確定済み
Sources/
  App.swift                    SwiftUI の画面。状態・計測値・ログを表示
  AudioEngineHost.swift         AVAudioSession / AVAudioEngine / AEC / RMS 計測 / 再生
  Transcriber.swift             SpeechAnalyzer(SpeechTranscriber/DictationTranscriber両対応)ラッパー。採用は DictationTranscriber。設計書§13参照
  TtsEngine.swift               Kokoro 呼び出しとベンチ計測
  VoiceLoop.swift               状態機械・barge-in 判定・AEC テスト
  FoundationModelsCheck.swift   FoundationModels が英語テキストで使えるかの起動時チェック（確認済み・問題なし）
Resources/
  KokoroModel/           Kokoro-82M の重み一式（約318MB、同梱・オフラインロード用）
```

`VoiceLoop.swift` の状態機械は設計書 §07 の縮小版。
ここで得た遷移の実態を、本番の `sessionMachine` に持ち込む。

## 検証後にやること

結果を設計書の §09 と §14 に記録する。特に以下は本番設計に直接効く。

- AEC の実測差分（barge-in の閾値設計の根拠になる）
- Kokoro の RTF（文単位チャンクの分割粒度を決める根拠になる）
- ウォームアップ時間（セッション開始時のプリロード設計の根拠になる）
