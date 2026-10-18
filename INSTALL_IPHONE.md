# UTube MusicをiPhoneに入れる（Windows / 無料）

対象: iPhone 14、利用者申告 iOS 27.0.1。2026-10-18。

SideStoreとLocalDevVPNがまだ入っていない方の手順です。初回はWindows PCとiPhoneをUSBケーブルで接続します。Apple Account・端末パスコードの入力はご本人が行ってください。このアプリの開発者へ送る必要はありません。

## 1. iPhoneにLocalDevVPNを入れる

iPhoneで[LocalDevVPNのApp Storeページ](https://apps.apple.com/jp/app/localdevvpn/id6755608044)を開いて「入手」します。無料です。一般の月額VPNサービスへの加入は不要です。似た名前の別VPNを契約する必要はありません。

## 2. WindowsからSideStoreを入れる

[SideStore公式の準備ページ](https://docs.sidestore.io/docs/installation/prerequisites)と[導入ページ](https://docs.sidestore.io/docs/installation/install)を開いて進めます。手順は更新されるため、表示が異なる場合は公式の最新画面を優先してください。

1. Windows側でAppleのiTunesまたはAppleデバイスの接続ソフトを用意する。すでにiTunesでiPhoneを認識できる場合は、その環境を使います。
2. 公式準備ページからWindows用iloaderをダウンロードし、導入する。MSIが推奨されています。
3. iPhoneをUSBケーブルでつなぎ、iPhone側の「このコンピュータを信頼」を承認する。
4. iloaderでご本人のApple Accountにログインし、接続したiPhoneを選択する。
5. `Install SideStore (Stable)` を選ぶ。
6. iPhoneの「設定 → 一般 → VPNとデバイス管理」でご本人の開発用アプリを信頼する。再起動が求められたら行う。
7. 「設定 → プライバシーとセキュリティ → デベロッパモード」を有効にし、案内どおり再起動・確認する。
8. Wi-Fiにつなぎ、LocalDevVPNのConnectで接続する。
9. SideStoreを開いて、iloaderと同じApple Accountでログインする。
10. My Appsで、最初にSideStore自身の期限カウンターを押して更新する。署名証明書の作成・更新に関する確認は公式手順に沿ってご本人が行う。

この操作はAppleの有料Developer Programへの加入ではありません。無料アカウントの通常の署名期限は7日です。

## 3. UTube MusicのIPAを入れる

**Xcodeビルド成功後に作成したIPAを使ってください。ソースコードZIPはインストールできません。**

1. Windowsにある `UTubeMusic-0.1.0-unsigned.ipa` を、ご自身のiCloud Driveや普段使うファイル転送手段でiPhoneの「ファイル」アプリへ渡す。メールなどで他人へ配布する必要はありません。
2. iPhoneをWi-Fiへ接続し、LocalDevVPNをConnectにする。
3. SideStore → My Apps → 追加（＋）からIPAを選択し、署名・インストールが終わるまで待つ。
4. ホーム画面の「UTube Music」を開く。

`unsigned` は、SideStoreがご本人の無料開発署名を付ける前のファイルという意味です。証明書やApple AccountのパスワードをIPAへ埋め込んでいません。

## 4. 最初の動作確認

1. 検索画面で、保存する権利・許可のある曲を1曲検索するか、YouTubeの曲のリンクを入力する。
2. 保存ボタン → お気に入り・プレイリストを選ぶ →「曲を保存」。完了までアプリを開く。
3. ライブラリから再生する。
4. iPhoneの画面をロックし、再生が続くか・ロック画面から操作できるか確認する。
5. 保存後は機内モードでも再生できるか確認する。

取得元の仕様・制限により、保存できない曲があります。エラー時は「保存の状況」から再試行します。保存が完了していない曲はライブラリへ登録しません。

## 毎週の更新

期限が切れる前に、Wi-Fi → LocalDevVPNをConnect → SideStore → My Appsで**UTube MusicとSideStore自身の両方**を更新します。期限が7日に戻ることを確認します。更新操作は無料です。初回設定後は通常Windows接続は不要です。

期限切れやペアリングの失効でSideStoreを開けなくなったら、アプリを削除せずWindowsからの復旧を検討してください。アプリを削除すると、その中の曲も削除されます。

## バックアップ

ファイルアプリの「このiPhone内 → UTube Music → UTubeMusic」フォルダーを丸ごと別の場所へコピーします。音声・画像・`library.json`を一緒に保管してください。アプリを終了してからコピー・復元します。

SideStoreの更新や再導入で困った場合は、エラーメッセージと発生した手順を確認してください。パスワード・認証コード・ペアリングファイルは共有しないでください。
