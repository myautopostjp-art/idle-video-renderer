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

# 描画フィルタ:背景 → タイマー → 上部テキスト → 下部テキスト
VF="scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920"
VF="$VF,drawtext=text='%{eif\:trunc((${DURATION}-t)/60)\:d\:2}\\:%{eif\:mod(trunc(${DURATION}-t)\,60)\:d\:2}':fontfile=${FONT}:fontcolor=white:fontsize=140:x=(w-text_w)/2:y=(h-text_h)/2:font=monospace:box=1:boxcolor=black@0.4:boxborderw=44"
VF="$VF,drawtext=textfile=${TOP_TEXT_FILE}:fontfile=${FONT}:fontcolor=white:fontsize=64:x=(w-text_w)/2:y=120:box=1:boxcolor=black@0.5:boxborderw=20:line_spacing=10"
VF="$VF,drawtext=textfile=${BOTTOM_TEXT_FILE}:fontfile=${FONT}:fontcolor=white:fontsize=42:x=(w-text_w)/2:y=h-280:box=1:boxcolor=black@0.5:boxborderw=16:line_spacing=8"

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
