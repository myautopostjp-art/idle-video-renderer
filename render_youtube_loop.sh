#!/bin/bash
# YouTube横型・高品質ループ動画 生成スクリプト(環境音+BGM合成版)
# 使い方: render_youtube_loop.sh <素材動画URL> <BGM URL or none> <長さ(秒)> <出力ファイル名> <BGM音量(0.0-1.0)>
set -e

SOURCE_URL="$1"
BGM_URL="$2"
DURATION_SEC="${3:-3600}"
OUTPUT_FILE="${4:-output.mp4}"
BGM_VOLUME="${5:-0.25}"

if [ -z "$SOURCE_URL" ]; then
  echo "エラー: 素材動画URLを指定してください"
  exit 1
fi

echo "=== 素材動画をダウンロード中 ==="
curl -sL "$SOURCE_URL" -o source.mp4
ls -la source.mp4

echo "=== 素材の音声トラック有無を確認 ==="
HAS_AUDIO=$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 source.mp4 || true)
if [ -n "$HAS_AUDIO" ]; then
  echo "→ 音声トラックあり(環境音を使用)"
else
  echo "→ 音声トラックなし(環境音は使用不可)"
fi

echo "=== 映像を${DURATION_SEC}秒にループ処理中(横型1920x1080) ==="
ffmpeg -y -stream_loop -1 -i source.mp4 \
  -t "$DURATION_SEC" \
  -vf "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080" \
  -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p \
  looped_video.mp4

if [ -n "$HAS_AUDIO" ]; then
  echo "=== 環境音を${DURATION_SEC}秒にループ処理中 ==="
  ffmpeg -y -stream_loop -1 -i source.mp4 \
    -t "$DURATION_SEC" \
    -vn -c:a aac -b:a 192k \
    looped_ambient.aac
fi

if [ -n "$BGM_URL" ] && [ "$BGM_URL" != "none" ]; then
  echo "=== BGMをダウンロード中 ==="
  curl -sL "$BGM_URL" -o bgm_source.mp3
  ls -la bgm_source.mp3

  echo "=== BGMを${DURATION_SEC}秒にループ処理中 ==="
  ffmpeg -y -stream_loop -1 -i bgm_source.mp3 \
    -t "$DURATION_SEC" \
    -c:a aac -b:a 192k \
    looped_bgm.aac

  if [ -n "$HAS_AUDIO" ]; then
    echo "=== 環境音とBGMをミックス中(BGM音量: ${BGM_VOLUME}) ==="
    ffmpeg -y -i looped_ambient.aac -i looped_bgm.aac \
      -filter_complex "[1:a]volume=${BGM_VOLUME}[bgm];[0:a][bgm]amix=inputs=2:duration=first:dropout_transition=0[aout]" \
      -map "[aout]" -c:a aac -b:a 192k mixed_audio.aac
    FINAL_AUDIO="mixed_audio.aac"
  else
    echo "=== 環境音なし、BGMのみ使用 ==="
    FINAL_AUDIO="looped_bgm.aac"
  fi
else
  if [ -n "$HAS_AUDIO" ]; then
    echo "=== BGMなし、環境音のみ使用 ==="
    FINAL_AUDIO="looped_ambient.aac"
  else
    echo "エラー: 音声トラックもBGMもありません。音のない動画になります"
    FINAL_AUDIO=""
  fi
fi

echo "=== 映像と音声を結合中 ==="
if [ -n "$FINAL_AUDIO" ]; then
  ffmpeg -y -i looped_video.mp4 -i "$FINAL_AUDIO" \
    -c:v copy -c:a aac -shortest \
    "$OUTPUT_FILE"
else
  cp looped_video.mp4 "$OUTPUT_FILE"
fi

echo "=== 完了: $OUTPUT_FILE ==="
ls -la "$OUTPUT_FILE"
