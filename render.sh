#!/bin/bash
# =====================================================
# 放置動画レンダリングスクリプト(FFmpeg版)
# 使い方: ./render.sh <画像URL> <BGM URL or "none"> <尺(秒)> <出力ファイル名> <上部テキストファイル> <下部テキストファイル>
# 例(BGMあり): ./render.sh "https://..." "https://..." 3600 output.mp4 top.txt bottom.txt
# 例(無音)  : ./render.sh "https://..." "none" 3600 output.mp4 top.txt bottom.txt
# =====================================================
set -e

IMAGE_URL="$1"
BGM_URL="$2"
DURATION="${3:-3600}"   # デフォルト60分
OUTPUT="${4:-output.mp4}"
TOP_TEXT_FILE="${5:-top.txt}"
BOTTOM_TEXT_FILE="${6:-bottom.txt}"

# テキストファイルが渡されなかった場合のデフォルト(存在しなければ空ファイルを作る)
[ -f "$TOP_TEXT_FILE" ] || echo "" > "$TOP_TEXT_FILE"
[ -f "$BOTTOM_TEXT_FILE" ] || echo "" > "$BOTTOM_TEXT_FILE"

echo "=== 素材ダウンロード ==="
curl -L -o bg.jpg "$IMAGE_URL"
if file bg.jpg | grep -qi html; then
  echo "エラー: 画像のダウンロードに失敗しました(HTMLが返されました)"; exit 1
fi

# BGMが"none"または空なら無音モード
SILENT=false
if [ -z "$BGM_URL" ] || [ "$BGM_URL" = "none" ]; then
  SILENT=true
  echo "=== 無音モードで実行します ==="
else
  curl -L -o bgm.mp3 "$BGM_URL"
  if file bgm.mp3 | grep -qi html; then
    echo "エラー: BGMのダウンロードに失敗しました(HTMLが返されました)"; exit 1
  fi
fi
ls -la bg.jpg

# 日本語対応フォント(事前にrender.yml側でfonts-noto-cjkをインストールしておくこと)
FONT="/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"

# 文字色
#
# 【白にした理由】
# 以前は淡い黄(#FFE9B3)だったが、一覧に縮小されると背景の空や灯りに
# 溶けて読めなかった。白に黒縁のほうが、どの絵の上でも判別できる。
TEXT_COLOR="#FFFFFF"
BORDER_COLOR="black"

# タイマーの大きさ
#
# 140 から 110 に下げた。数字を大きく見せるより、
# 背景の情景を主役にする方針。読みやすさは白+黒縁で確保する。
TIMER_SIZE=110
TIMER_BORDER=7

# 画面に出す文字をタイマー(と無音表示)だけにするか
#
# 【1にした理由】
# 上下に日本語の文字を焼き込んでいたが、焼き込んだ文字は翻訳されない。
# 日本語が読めない視聴者には意味不明な文字が乗るだけになる。
# 数字は世界共通なので、タイマーだけなら誰にでも通じる。
# 説明文はTikTokが自動翻訳するので、伝えたいことはそちらに書く。
#
#   0 … 上下のテキストも出す(以前の動作)
#   1 … タイマーだけにする(現在)
TIMER_ONLY=1

# 無音モードのときに出す表示
#
# 音が出ないことを意図的なものだと伝えないと、
# 「壊れている」と思われて離脱される。
# 日英併記にしてあるのは、焼き込んだ文字が翻訳されないため。
#
# 位置は、以前に上部テキストを置いていた2行分のすぐ下。
SILENT_LABEL="無音 / Silent"
SILENT_LABEL_SIZE=64
SILENT_LABEL_Y=290

# 描画フィルタ:背景 → タイマー → (無音表示) → (上下テキスト)
VF="scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920"

# タイマー(位置は画面中央のまま)
VF="$VF,drawtext=text='%{eif\:trunc((${DURATION}-t)/60)\:d\:2}\\:%{eif\:mod(trunc(${DURATION}-t)\,60)\:d\:2}':fontfile=${FONT}:fontcolor=${TEXT_COLOR}:fontsize=${TIMER_SIZE}:x=(w-text_w)/2:y=(h-text_h)/2:font=monospace:bordercolor=${BORDER_COLOR}:borderw=${TIMER_BORDER}"

# 無音のときだけ「無音 / Silent」を出す
if [ "$SILENT" = true ] && [ -n "${SILENT_LABEL}" ]; then
  echo "無音表示を入れます: ${SILENT_LABEL} (y=${SILENT_LABEL_Y})"
  VF="$VF,drawtext=text='${SILENT_LABEL}':fontfile=${FONT}:fontcolor=${TEXT_COLOR}:fontsize=${SILENT_LABEL_SIZE}:x=(w-text_w)/2:y=${SILENT_LABEL_Y}:bordercolor=${BORDER_COLOR}:borderw=5"
fi

if [ "${TIMER_ONLY:-1}" != "1" ]; then
  VF="$VF,drawtext=textfile=${TOP_TEXT_FILE}:fontfile=${FONT}:fontcolor=${TEXT_COLOR}:fontsize=64:x=(w-text_w)/2:y=120:bordercolor=${BORDER_COLOR}:borderw=5:line_spacing=10"
  VF="$VF,drawtext=textfile=${BOTTOM_TEXT_FILE}:fontfile=${FONT}:fontcolor=${TEXT_COLOR}:fontsize=42:x=(w-text_w)/2:y=h-280:bordercolor=${BORDER_COLOR}:borderw=4:line_spacing=8"
fi

echo "=== レンダリング開始 (${DURATION}秒 = $((DURATION/60))分, 無音=${SILENT}) ==="

if [ "$SILENT" = true ]; then
  ffmpeg -y \
    -loop 1 -framerate 2 -i bg.jpg \
    -t "$DURATION" \
    -vf "$VF" \
    -c:v libx264 -preset ultrafast -tune stillimage -r 2 -pix_fmt yuv420p \
    -an \
    "$OUTPUT"
else
  ffmpeg -y \
    -loop 1 -framerate 2 -i bg.jpg \
    -stream_loop -1 -i bgm.mp3 \
    -t "$DURATION" \
    -vf "$VF" \
    -c:v libx264 -preset ultrafast -tune stillimage -r 2 -pix_fmt yuv420p \
    -c:a aac -b:a 128k -shortest \
    "$OUTPUT"
fi

echo "=== 完成 ==="
ffprobe -v quiet -show_entries format=duration,size -of default=noprint_wrappers=1 "$OUTPUT"
