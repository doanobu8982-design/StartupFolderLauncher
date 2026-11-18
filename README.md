# StartupFolderLauncher

[English Documentation (README.en.md)](README.en.md)

Windows標準のスタートアップフォルダの「ショートカットを入れるだけ」という手軽さをそのままに、**UAC確認なしでの管理者起動**、**GUIによる起動順序の並び替え**、**黒窓（コンソール）ゼロの完全不可視起動**、**起動後ウィンドウの自動トレイ格納（LINE等のスプラッシュ画面誤閉じ防止対応）**、**画面ロック解除時の死活監視・自動復帰**を実現するポータブルランチャーです。

---

## クイックスタート（3ステップ）

1. **[Releases ページ](https://github.com/doanobu8982-design/StartupFolderLauncher/releases/latest) から配布 ZIP（例: `StartupFolderLauncher_v1.1.0.zip`）をダウンロード**し、任意の恒久的なフォルダ（例: `C:\Tools\StartupFolderLauncher`）へ解凍します。
2. **`スタートアップ` フォルダ** に、PC起動時に自動起動したいアプリのショートカット（`.lnk`）や実行ファイル（`.exe`, `.bat`, `.cmd`）を入れます。
3. **`インストール.bat` をダブルクリック**し、UAC（管理者昇格）プロンプトで「はい」を選択して完了です。

> 日常の起動順序変更・管理者権限の切り替え・死活監視の設定は **`管理画面を開く.exe`** からすべてマウス操作だけで行えます。

---

## 主な特徴

* **完全黒窓ゼロ化（`launcher.exe` / `管理画面を開く.exe`）**:
  * ネイティブGUI実行ファイルにより、`powershell.exe` 起動時に発生しがちな一瞬のコンソール点滅（黒窓）が一切発生しません。
* **ワンクリックで管理者権限起動・通常起動を切り替え**:
  * 管理画面の「管理者」チェックボックスをONにするだけで、UACプロンプトをスキップして管理者特権で起動できます。OFFの場合はエクスプローラーのCOMインターフェース（`Shell.Application`）経由で安全に通常権限で起動します。
* **起動順序の並び替え・タスクバー待機**:
  * 管理画面の「▲ 上へ」「▼ 下へ」で起動順序を設定でき、ログオン時はタスクバー（`Shell_TrayWnd`）の準備完了を待機してから順次起動するため、タスクトレイ登録漏れを防ぎます。
* **自動ウィンドウ閉じ（トレイ格納）＆二段階起動プロファイル（`auto_close_profile`）**:
  * 起動直後に開くウィンドウを自動で閉じてタスクトレイへ格納できます（`auto_close_window`）。
  * **`config.default.json` に LINE 用の標準プリセットを搭載**：`auto_close_profile.wait_process` により、ゲートプロセス（LINE の場合は `LineMediaPlayer`）が立ち上がるまでクローズ処理を待機するため、スプラッシュ画面や初期化中に誤ってアプリを終了させてしまう問題を防止します。
* **安全設計：死活監視はデフォルト OFF**:
  * 画面ロック解除時（`SessionUnlock`）のプロセス死活監視・自動復帰は、管理画面で明示的に「監視」をONにしたアプリのみを対象とします。実行中プロセス一覧から監視対象を簡単に指定できるプロセスピッカーも備えています。
* **排他制御・日本語パス対応・自動ログローテーション**:
  * 名前付きミューテックス（`Global\StartupFolderLauncher_Mutex`）による多重起動防止、全角文字・スペースを含むパスの安全な処理、`launcher.log`（UTF-8 BOMなし）の自動行数制限を備えています。

---

## 配布パッケージの構成

```text
StartupFolderLauncher/
├── スタートアップ/             # 自動起動したいショートカットや実行ファイルを配置
│   └── .gitkeep
├── インストール.bat            # 【初回のみ】タスクスケジューラへ自動登録（自動UAC昇格）
├── アンインストール.bat        # 【削除時】登録タスクを一括削除（自動UAC昇格）
├── 管理画面を開く.exe          # 【日常用】GUI管理画面を開く（黒窓なし）
├── launcher.exe                # 【内部・手動用】完全不可視ネイティブランチャー
├── config.default.json         # 設定テンプレート（LINE用二段階起動プリセット同梱）
├── config.json                 # 動作設定ファイル（初回起動時に自動生成）
├── launcher.ps1                # ランチャー処理本体
├── view_status.ps1             # 管理画面GUIスクリプト（Windows Forms）
├── scripts/                    # 内部補助スクリプト
│   ├── register_task.ps1       # タスクスケジューラ登録スクリプト
│   ├── unregister_task.ps1     # タスクスケジューラ解除スクリプト
│   └── window_closer.ps1       # ウィンドウ自動トレイ格納スクリプト
├── launcher.log                # 実行ログ（初回実行時に自動生成）
├── LICENSE                     # MIT License
├── README.md                   # 日本語ドキュメント
└── README.en.md                # 英語ドキュメント
```

---

## セットアップ・アンインストール

### タスクスケジューラへの登録
`インストール.bat` をダブルクリックして実行すると、以下の2つのタスクがタスクスケジューラに登録されます。
* **`StartupFolderLauncher`**: ユーザーログオン時（`LogonTrigger`）に `launcher.exe` を実行
* **`StartupFolderLauncher_Unlock`**: 画面ロック解除時（`SessionUnlock`）に `launcher.exe -IsUnlockTrigger` を実行

### 登録の解除
`アンインストール.bat` をダブルクリックすると、上記2つのタスクがタスクスケジューラから完全に削除されます。

---

## 設定ファイル（`config.json` / `config.default.json`）

初回起動時に `config.default.json` をひな形として `config.json` が生成されます。管理画面（`管理画面を開く.exe`）での変更は即座に `config.json` へ保存されます。

```json
{
  "settings": {
    "stagger_interval_ms": 500,
    "logon_check_shell": true,
    "shell_timeout_sec": 30,
    "auto_close_timeout_sec": 300,
    "max_log_lines": 200,
    "window_width": 860,
    "window_height": 600,
    "launch_order": []
  },
  "overrides": [
    {
      "match_name": "LINE.lnk",
      "enabled_watch": true,
      "run_as_admin": false,
      "auto_close_window": true,
      "auto_close_profile": {
        "wait_process": "LineMediaPlayer"
      },
      "watch_process_name": "LINE",
      "arguments": "",
      "hidden": false
    }
  ]
}
```

### 基本設定 (`settings`)
| 項目名 | 型 | デフォルト値 | 説明 |
| :--- | :--- | :--- | :--- |
| `stagger_interval_ms` | 数値 | `500` | アプリケーション起動ごとの待機時間（ミリ秒）。 |
| `logon_check_shell` | 真偽値 | `true` | ログオン時にタスクバーの準備完了を待つかどうか。 |
| `shell_timeout_sec` | 数値 | `30` | タスクバー待機の最大タイムアウト（秒）。 |
| `auto_close_timeout_sec` | 数値 | `300` | ウィンドウ自動閉じ（`window_closer.ps1`）の最大監視タイムアウト（秒）。 |
| `max_log_lines` | 数値 | `200` | `launcher.log` の最大保持行数。 |
| `window_width` | 数値 | `860` | 管理画面ウィンドウの保存幅（ピクセル、最小 860）。 |
| `window_height` | 数値 | `600` | 管理画面ウィンドウの保存高さ（ピクセル、最小 500）。 |
| `launch_order` | 配列 | `[]` | 起動順序を定義するファイル名の配列。 |

### 個別オーバーライド (`overrides`)
| 項目名 | 説明 |
| :--- | :--- |
| `match_name` | ファイル名のワイルドカード照合パターン（例: `LINE.lnk`, `Discord*`）。 |
| `enabled_watch` | `true` の場合のみ、画面ロック解除時に死活監視・自動再起動を実施（省略時は `false`）。 |
| `run_as_admin` | `true` の場合、UACをスキップして管理者権限で起動。 |
| `auto_close_window` | `true` の場合、起動後のメインウィンドウを自動で閉じてトレイに格納。 |
| `auto_close_profile` | ウィンドウ自動閉じの詳細プロファイル。`wait_process` を指定すると、そのプロセスが起動するまでクローズ処理を待機します（例: LINE の `LineMediaPlayer` によりスプラッシュ画面誤閉じを防止）。 |
| `watch_process_name` | 死活監視対象とするプロセス名（`.exe` なし）。 |
| `arguments` | アプリケーションに渡す追加コマンドライン引数。 |
| `hidden` | `true` の場合、ウィンドウを非表示で起動。 |

---

## トラブルシューティング

1. **画面ロック解除時にアプリが自動起動しない**
   * `管理画面を開く.exe` で対象アプリの「監視」列にチェックが入っているか確認してください（デフォルトは安全のため OFF です）。
2. **起動しているのに毎回二重起動してしまう**
   * ショートカット名と常駐プロセス名が異なる場合があります。管理画面の「監視プロセス変更」ボタンから実行中プロセス一覧を開き、正しいプロセス名を選択してください。
3. **LINE などのアプリが起動直後に閉じて終了してしまう**
   * `config.default.json` に標準搭載されている `LINE.lnk` の `auto_close_profile`（`"wait_process": "LineMediaPlayer"`）が有効になっているか確認してください。ショートカット名が `LINE.lnk` 以外の場合は、合わせて `match_name` を調整してください。
4. **管理者権限で動かしたいのに UAC ダイアログが出る**
   * 管理画面の「管理者」チェックボックスを ON にしてください。

---

## ライセンス

本プロジェクトは [MIT License](LICENSE) の下で公開されています。
