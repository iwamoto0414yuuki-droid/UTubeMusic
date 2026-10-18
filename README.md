# UTube Music

iPhoneに曲を保存し、同じアプリでお気に入り・プレイリスト・オフライン再生を扱う個人用音楽アプリ。AI機能はありません。YouTube / YouTube Music / Spotifyの公式アプリではありません。

対象: iPhone 14 / 利用者申告 iOS 27.0.1。開発PC: Windows。更新日: 2026-10-18。

## 現在の状態

**0.1.0のSideStore用IPAを生成しました。** 公開リポジトリの標準macOSランナーで、Xcodeのシミュレーター検証・実機向けARM64ビルドに成功しました。[成功したビルドと成果物](https://github.com/iwamoto0414yuuki-droid/UTubeMusic/actions/runs/39120755839)。Pythonの8件とネイティブの13件、合計21件のテストに通っています。

**iPhone 14 / iOS 27.0.1の実機での導入・YouTubeからの保存・ロック中再生はまだ未確認の試作版です。** シミュレーターでの検証と実機での利用実績を区別してください。最初に[Windowsからの導入手順](INSTALL_IPHONE.md)に沿って1曲で確認します。

- SwiftUI: ホーム / 検索 / ライブラリ、常設ミニプレイヤー、全面再生画面。
- 端末内の組み込みCPython + yt-dlp: 曲・アーティスト検索、曲URL、AAC音声の取得情報解析。
- Swift URLSession: 音声専用の転送、進行状況・キャンセル・再試行。解析URLを永続保存せず、再試行で取り直す。
- AVFoundation: 再生可能な音声だけをライブラリ登録。ローカル再生、Background Audio、ロック画面・イヤホン操作、着信中断、イヤホン切断時の停止を実装。
- 順番 / シャッフル / 1曲・全曲リピート、再生キュー。
- お気に入り、複数プレイリスト、曲順変更、曲の取り外し、名前変更・削除。
- ライブラリ削除後の再保存、原子的な索引保存、破損した索引の保護。
- 音声ファイルの手動読み込み、共有、ファイルアプリからのバックアップ。

これらは**コード上の実装内容**です。iOS上での動作実績とは区別してください。特に組み込みPython・WebKitプラグインの端末内取得は実験段階です。ログインが必要な曲、ライブ配信、AACが取得できない曲には現在対応しません。取得時は画面を開いてください。保存した曲の再生はBackground Audioを使います。公式YouTube Musicの検索・推薦APIは使わず、YouTubeの検索結果を音楽用UIで扱います。音楽以外の検索結果を完全に除外する仕組みではありません。

## 無料でビルドする経路

GitHub公式は、公開リポジトリで標準GitHub-hosted runnerを使うActions実行を無料と案内しています。**有料のlarger runnerは使いません。** 今回のワークフローは公開リポジトリの場合のみmacOSジョブを実行します。非公開リポジトリでは実行をスキップし、無料枠から有料利用へ流れる構成にしません。

手動実行のみ、同時1件、最大30分。成果物の保持は1日、キャッシュは使いません。Actions / Packagesの保存枠も共有されるため、他のリポジトリを含めたアカウント全体の保存量と請求設定を実行前に確認します。今回の設定だけでアカウント全体の課金設定を変更することはできません。無料を条件として、枠超過で課金する設定にはしません。

1. このフォルダーだけを新しいリポジトリのルートに置く。既存LocalTubeや親フォルダー全体をアップロードしない。
2. ソースの公開について利用者の同意を得る。2026-10-18に本人の承認を得て、[UTubeMusic](https://github.com/iwamoto0414yuuki-droid/UTubeMusic) にソースのみを公開しました。曲・認証情報・既存LocalTubeのデータは含めません。
3. Actions → `Build personal iPhone app (free standard runner)` → Run workflow。
4. シミュレーターのビルド・ネイティブテストを通してから実機用ビルドを行う。
5. 成功時の `UTubeMusic-0.1.0-SideStore` からIPAとSHA256を取得する。失敗はログを調べて修正し、成功するまで導入用として配布しない。

出力: `build/UTubeMusic-0.1.0-unsigned.ipa`。Windowsへ取得した配布用コピーは `release/` に保存します。これは自分のApple AccountでSideStoreが署名する前のIPAです。署名証明書・パスワード・ペアリングファイルをCIへ送る必要はありません。成果物のActions保管期限は1日なので、取得したIPAを手元に保管してください。

Macがある場合はXcodeとXcodeGenを用意して `bash scripts/build_ipa.sh` で同じビルドを実行できます。Windowsでは実行できません。

## SideStoreで入れる

**SideStore・LocalDevVPN・無料Apple Accountによる通常の7日更新は無料**です。一般の有料VPN契約は不要です。初期設定ではWindowsとUSBケーブルを使います。

1. 公式手順に従いLocalDevVPNをApp Storeから導入。
2. WindowsのiloaderとAppleの接続ソフトを用意し、USB接続、PCの信頼を行う。
3. 本人がApple Accountへログインし、SideStore Stableを導入。
4. iPhoneで開発者の信頼・Developer Modeを設定。これらの認証・端末設定は本人が行う。
5. Wi-Fi + LocalDevVPN接続中にSideStoreを開き、最初にSideStore自身を更新。
6. 成功したIPAをiPhoneの「ファイル」に置き、SideStoreのMy Appsの追加操作から選ぶ。
7. 起動・曲の保存・機内モード再生・ロック中の連続再生を確認。

通常の更新: Wi-Fi → LocalDevVPNオン → SideStore → My Apps → UTube MusicとSideStoreの期限を更新。通常7日が切れる前に行います。自動更新は毎回成功すると仮定しません。期限切れ時はアプリを削除せず再署名を検討し、ライブラリを保護します。SideStore自身の期限切れやペアリングの失効時にはWindowsからの復旧が必要になる場合があります。

## バックアップ

「ファイル」→「このiPhone内」→「UTube Music」→「UTubeMusic」をフォルダーごと別の場所へコピーします。音声・画像・`library.json` をまとめて保管してください。アプリを終了してからコピー・復元します。`library.previous.json` は直前の索引です。誤削除に対する音声ファイルのごみ箱ではありません。

## 検証

Windowsで実施済み: 抽出契約のオフラインユニットテスト8件、Swift構文ツリー検査、Python構文、YAMLの無料ビルド条件、公式ランタイムSHA256照合、実配布ファイルの標準ライブラリと68個のネイティブ部品を使った同梱レイアウト検査。Swift構文検査は型検査やXcodeビルドの代用にはなりません。部品同梱の検査でもiOSバイナリ自体は実行していません。

```powershell
python -m unittest discover -s tests_python -v
```

macOS CIで `Tests/CoreTests.swift` と `Tests/ScreenCaptureTests.swift` の**13件に通っています**。組み込みPython・SSL・ctypes・WebKitプロバイダーの読み込みと端末内JavaScript実行、キュー・シャッフル・リピート、削除/再保存、索引破損・書込失敗の保護、プレイリストの順序、ファイル名・転送範囲を検証しました。スクリーンショットの再生画面はテスト用に生成した無音ファイルを使用し、音楽ファイルは配布物へ同梱していません。YouTubeとの実通信や実機のバックグラウンド再生までテストしたことにはなりません。

実機で必要な確認:

- SideStoreで導入・期限更新 → ライブラリ維持。
- 許可されたサンプル曲1件を端末内で検索/URL取得 → AAC保存 → 機内モード再生。
- ロック中の曲送り・最後まで連続再生、イヤホン操作・切断、着信後の復帰。
- 順番・シャッフル・各リピート、再起動後の曲とプレイリスト。
- キャンセル/失敗/再試行、削除→再保存、低空き容量、バックアップ復元。

## デザイン

`design/index.html` はサンプルデータの操作可能なレイアウト確認用です。実際の音楽取得・再生は行いません。ネイティブ画面と細部は異なります。`node design/serve.mjs` で `http://127.0.0.1:8876/` を開けます。主要操作は44pt以上、下部3タブ、上にミニプレイヤー、全面再生画面の中央に大きい再生ボタンを置きます。色はチャコール・アイボリー・コーラル。

ネイティブのホーム・再生画面もシミュレーター上のテストで描画し、画像を成果物へ保存します。再生画面は画面の高さに合わせてジャケットサイズ・余白を変えます。実機の文字サイズ変更・VoiceOver・キーボード操作は引き続き確認が必要です。

Google Stitchもブラウザで試しましたが、追加規約の同意画面で停止し、デザイン生成は実施していません。Stitchの生成物を使ったとは扱いません。

## 一次資料

- [GitHub Actionsの無料条件と保存枠](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
- [SideStoreの前提条件](https://docs.sidestore.io/docs/installation/prerequisites)
- [SideStore導入手順](https://docs.sidestore.io/docs/installation/install)
- [SideStore FAQ](https://docs.sidestore.io/docs/faq)
- [LocalDevVPN日本App Store掲載](https://apps.apple.com/jp/app/localdevvpn/id6755608044)
- [Python iOS組み込み](https://docs.python.org/3.13/using/ios.html)
- [Python Apple Support](https://github.com/beeware/Python-Apple-support)
- [yt-dlp EJS](https://github.com/yt-dlp/yt-dlp/wiki/EJS)
- [Apple WebKit用の実験的プラグイン](https://github.com/grqz/yt-dlp-apple-webkit-jsi)
- [Appleのバックグラウンド再生設定](https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback)

依存はバージョンとSHA256を固定。Python-Apple-support 3.13-b14 / yt-dlp 2026.8.19 / yt-dlp-ejs 0.8.0 / certifi 2026.7.22 / WebKit plugin 0.1.1。上流の変更対応はハッシュと互換性を確認して更新します。権利・許可のあるコンテンツを対象にしてください。
