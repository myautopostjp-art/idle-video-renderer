#!/bin/bash
# =====================================================
# BGM版・天候変化レンダリングスクリプト(FFmpeg版・雨オーバーレイ対応)
# 使い方: ./render_bgm_weather.sh <BGM URL> <出力ファイル名> <上部テキストファイル> <下部テキストファイル> \
#           [--rain <雨オーバーレイURL or "none">] <画像URL1> <画像URL2> ... <画像URLN>
# 例(雨オーバーレイなし): ./render_bgm_weather.sh "https://.../bgm.mp3" output.mp4 top.txt bottom.txt \
#       "https://.../weather_1.png" ... "https://.../weather_6.png"
# 例(雨オーバーレイあり): ./render_bgm_weather.sh "https://.../bgm.mp3" output.mp4 top.txt bottom.txt \
#       --rain "https://.../rain_overlay.mp4" \
#       "https://.../weather_1.png" ... "https://.../weather_6.png"
# =====================================================
set -e

BGM_URL="$1"
OUTPUT="$2"
TOP_TEXT_FILE="$3"
BOTTOM_TEXT_FILE="$4"
shift 4

RAIN_URL="none"
if [ "$1" = "--rain" ]; then
  RAIN_URL="$2"
  shift 2
fi

IMAGE_URLS=("$@")

N=${#IMAGE_URLS[@]}
if [ "$N" -lt 2 ]; then
  echo "エラー: 画像は2枚以上必要です"; exit 1
fi

[ -f "$TOP_TEXT_FILE" ] || echo "" > "$TOP_TEXT_FILE"
[ -f "$BOTTOM_TEXT_FILE" ] || echo "" > "$BOTTOM_TEXT_FILE"

XFADE_SEC=8
TOTAL_DURATION=3600
# 各画像のソース秒数(切り上げ): (3600 + (N-1)*8) / N
STAGE_SRC_SEC=$(( (TOTAL_DURATION + (N-1)*XFADE_SEC + N - 1) / N ))

echo "=== 素材ダウンロード(画像 ${N}枚) ==="
for i in "${!IMAGE_URLS[@]}"; do
  curl -L -o "bg_${i}.jpg" "${IMAGE_URLS[$i]}"
  if file "bg_${i}.jpg" | grep -qi html; then
    echo "エラー: 画像${i}のダウンロードに失敗しました(HTMLが返されました)"; exit 1
  fi
done

echo "=== BGMダウンロード ==="
curl -L -o bgm.mp3 "$BGM_URL"
if file bgm.mp3 | grep -qi html; then
  echo "エラー: BGMのダウンロードに失敗しました(HTMLが返されました)"; exit 1
fi

USE_RAIN=false
if [ "$RAIN_URL" != "none" ] && [ -n "$RAIN_URL" ]; then
  echo "=== 雨オーバーレイ素材ダウンロード ==="
  curl -L -o rain.mp4 "$RAIN_URL"
  if file rain.mp4 | grep -qi html; then
    echo "警告: 雨オーバーレイのダウンロードに失敗しました。雨演出なしで続行します"
  else
    USE_RAIN=true
  fi
fi

FONT="/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
TEXT_COLOR="#FFE9B3"
BORDER_COLOR="black"

# 入力オプション組み立て(画像N枚 + BGM1つ + 雨オーバーレイ(あれば))
INPUTS=()
for i in "${!IMAGE_URLS[@]}"; do
  INPUTS+=(-loop 1 -framerate 2 -t "$STAGE_SRC_SEC" -i "bg_${i}.jpg")
done
INPUTS+=(-stream_loop -1 -i bgm.mp3)
RAIN_INPUT_IDX=$N  # BGMの次のインデックス
if [ "$USE_RAIN" = true ]; then
  RAIN_INPUT_IDX=$((N + 1))
  INPUTS+=(-stream_loop -1 -i rain.mp4)
fi

# パーティクルは常時・一定の薄さで重ね続ける(時間による出現/消失なし)
PARTICLE_OPACITY=0.35

# スケール・クロップ
FILTER=""
for i in $(seq 0 $((N-1))); do
  FILTER="${FILTER}[$i:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1[v${i}];"
done

# xfadeチェーン(段階的に隣の画像とクロスフェード)
PREV="v0"
for i in $(seq 1 $((N-1))); do
  OFFSET=$(( i * (STAGE_SRC_SEC - XFADE_SEC) ))
  NEXT="x${i}"
  FILTER="${FILTER}[${PREV}][v${i}]xfade=transition=fade:duration=${XFADE_SEC}:offset=${OFFSET}[${NEXT}];"
  PREV="$NEXT"
done

# パーティクルオーバーレイ合成(screenブレンドで黒背景を透過、常時・一定の薄さで重ねる)
if [ "$USE_RAIN" = true ]; then
  FILTER="${FILTER}[${RAIN_INPUT_IDX}:v]scale=1080:1920,format=rgba,"
  FILTER="${FILTER}colorkey=black:0.15:0.1,"
  FILTER="${FILTER}colorchannelmixer=aa=${PARTICLE_OPACITY}[rainlayer];"
  FILTER="${FILTER}[${PREV}][rainlayer]overlay[rained];"
  PREV="rained"
fi

# タイマー・テキストオーバーレイ(最終ノードに適用)
FILTER="${FILTER}[${PREV}]drawtext=text='%{eif\:trunc((${TOTAL_DURATION}-t)/60)\:d\:2}\\:%{eif\:mod(trunc(${TOTAL_DURATION}-t)\,60)\:d\:2}':fontfile=${FONT}:fontcolor=${TEXT_COLOR}:fontsize=140:x=(w-text_w)/2:y=(h-text_h)/2:font=monospace:bordercolor=${BORDER_COLOR}:borderw=8[t1];"
FILTER="${FILTER}[t1]drawtext=textfile=${TOP_TEXT_FILE}:fontfile=${FONT}:fontcolor=${TEXT_COLOR}:fontsize=64:x=(w-text_w)/2:y=120:bordercolor=${BORDER_COLOR}:borderw=5:line_spacing=10[t2];"
FILTER="${FILTER}[t2]drawtext=textfile=${BOTTOM_TEXT_FILE}:fontfile=${FONT}:fontcolor=${TEXT_COLOR}:fontsize=42:x=(w-text_w)/2:y=h-280:bordercolor=${BORDER_COLOR}:borderw=4:line_spacing=8[vout]"

echo "=== レンダリング開始(天候変化${N}段階, 各源${STAGE_SRC_SEC}秒, 遷移${XFADE_SEC}秒) ==="

ffmpeg -y "${INPUTS[@]}" \
  -filter_complex "$FILTER" \
  -map "[vout]" -map "${N}:a" \
  -t "$TOTAL_DURATION" \
  -c:v libx264 -preset ultrafast -tune stillimage -r 2 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -shortest \
  "$OUTPUT"

echo "=== 完成 ==="
ffprobe -v quiet -show_entries format=duration,size -of default=noprint_wrappers=1 "$OUTPUT"
