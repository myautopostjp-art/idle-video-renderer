#!/bin/bash
# YouTube横型・高品質ループ動画 生成スクリプト
# 使い方: render_youtube_loop.sh <素材動画URL> <BGM URL or none> <長さ(秒)> <出力ファイル名>
set -e

SOURCE_URL="$1"
BGM_URL="$2"
DURATION_SEC="${3:-3600}"
OUTPUT_FILE="${4:-output.mp4}"

if [ -z "$SOURCE_URL" ]; then
  echo "エラー: 素材動画URLを指定してください"
  exit 1
fi

echo "=== 素材動画をダウンロード中 ==="
curl -sL "$SOURCE_URL" -o source.mp4
ls -la source.mp4

echo "=== ${DURATION_SEC}秒にループ処理中(横型1920x1080に統一) ==="
ffmpeg -y -stream_loop -1 -i source.mp4 \
  -t "$DURATION_SEC" \
  -vf "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080" \
  -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p \
  -an looped_video.mp4

if [ -n "$BGM_URL" ] && [ "$BGM_URL" != "none" ]; then
  echo "=== BGMをダウンロード中 ==="
  curl -sL "$BGM_URL" -o bgm_source.mp3
  ls -la bgm_source.mp3

  echo "=== BGMを${DURATION_SEC}秒にループ処理中 ==="
  ffmpeg -y -stream_loop -1 -i bgm_source.mp3 \
    -t "$DURATION_SEC" \
    -c:a aac -b:a 192k \
    looped_bgm.aac

  echo "=== 映像と音声を結合中 ==="
  ffmpeg -y -i looped_video.mp4 -i looped_bgm.aac \
    -c:v copy -c:a aac -shortest \
    "$OUTPUT_FILE"
else
  echo "=== 音声なし。映像のみ出力 ==="
  cp looped_video.mp4 "$OUTPUT_FILE"
fi

echo "=== 完了: $OUTPUT_FILE ==="
ls -la "$OUTPUT_FILE"
