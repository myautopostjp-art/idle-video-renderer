#!/bin/bash
# =====================================================
# 放置動画レンダリングスクリプト(FFmpeg版)
# 使い方: ./render.sh <画像URL> <BGM URL> <尺(秒)> <出力ファイル名>
# 例:     ./render.sh "https://..." "https://..." 3600 output.mp4
# =====================================================
set -e

IMAGE_URL="$1"
BGM_URL="$2"
DURATION="${3:-3600}"   # デフォルト60分
OUTPUT="${4:-output.mp4}"

echo "=== 素材ダウンロード ==="
curl -L -o bg.jpg "$IMAGE_URL"
curl -L -o bgm.mp3 "$BGM_URL"
ls -la bg.jpg bgm.mp3

# ダウンロード検証(GoogleドライブがHTMLを返した場合を検知)
if file bg.jpg | grep -qi html; then
  echo "エラー: 画像のダウンロードに失敗しました(HTMLが返されました)"; exit 1
fi
if file bgm.mp3 | grep -qi html; then
  echo "エラー: BGMのダウンロードに失敗しました(HTMLが返されました)"; exit 1
fi

echo "=== レンダリング開始 (${DURATION}秒 = $((DURATION/60))分) ==="
ffmpeg -y \
  -loop 1 -framerate 2 -i bg.jpg \
  -stream_loop -1 -i bgm.mp3 \
  -t "$DURATION" \
  -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,drawtext=text='%{eif\:trunc((${DURATION}-t)/60)\:d\:2}\\:%{eif\:mod(trunc(${DURATION}-t)\,60)\:d\:2}':fontcolor=white:fontsize=140:x=(w-text_w)/2:y=(h-text_h)/2:font=monospace:box=1:boxcolor=black@0.4:boxborderw=44" \
  -c:v libx264 -preset ultrafast -tune stillimage -r 2 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -shortest \
  "$OUTPUT"

echo "=== 完成 ==="
ffprobe -v quiet -show_entries format=duration,size -of default=noprint_wrappers=1 "$OUTPUT"
