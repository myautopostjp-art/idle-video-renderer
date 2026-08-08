#!/bin/bash
# =====================================================
# YouTube長尺BGM動画レンダリングスクリプト(お試し版)
# 配置場所: リポジトリの render_youtube_long.sh
#
# 構成: 導入部(LTX動画、動きあり) + ループ部分(天候チェーン静止画6枚、BGM)
# 引数: $1=導入動画URL $2=BGM URL $3=総尺(秒) $4=導入部秒数 $5=出力ファイル名 $6以降=ループ用画像URL(6枚)
# =====================================================
set -e

INTRO_VIDEO_URL="$1"
BGM_URL="$2"
TOTAL_DURATION="$3"
INTRO_DURATION="$4"
OUTPUT_FILE="$5"
shift 5
IMAGE_URLS=("$@")

echo "=== YouTube長尺動画レンダリング開始 ==="
echo "導入動画: $INTRO_VIDEO_URL"
echo "BGM: $BGM_URL"
echo "総尺: ${TOTAL_DURATION}秒 / 導入部: ${INTRO_DURATION}秒"
echo "ループ画像枚数: ${#IMAGE_URLS[@]}"

# ---- ①素材のダウンロード ----
echo "導入動画をダウンロード中..."
curl -L -s -o intro_video.mp4 "$INTRO_VIDEO_URL"

echo "BGMをダウンロード中..."
curl -L -s -o bgm.mp3 "$BGM_URL"

echo "ループ用画像をダウンロード中..."
IMG_COUNT=${#IMAGE_URLS[@]}
for i in "${!IMAGE_URLS[@]}"; do
  curl -L -s -o "loop_img_$i.png" "${IMAGE_URLS[$i]}"
done

# ---- ②ループ部分の尺を計算 ----
LOOP_DURATION=$((TOTAL_DURATION - INTRO_DURATION))
STAGE_DURATION=$((LOOP_DURATION / IMG_COUNT))
echo "ループ部分: ${LOOP_DURATION}秒 / 1段階あたり: ${STAGE_DURATION}秒"

# ---- ③各静止画をSTAGE_DURATION秒の動画に変換(Ken Burns等の演出なし、シンプルな静止表示) ----
for i in "${!IMAGE_URLS[@]}"; do
  ffmpeg -y -loop 1 -i "loop_img_$i.png" -t "$STAGE_DURATION" \
    -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2" \
    -c:v libx264 -pix_fmt yuv420p -r 30 "stage_$i.mp4"
done

# ---- ④ループ部分の静止画動画を全部つなげる ----
> concat_list.txt
for i in "${!IMAGE_URLS[@]}"; do
  echo "file 'stage_$i.mp4'" >> concat_list.txt
done
ffmpeg -y -f concat -safe 0 -i concat_list.txt -c copy loop_video.mp4

# ---- ⑤導入部とループ部分をつなげる(映像のみ、音声は後で合成) ----
echo "file 'intro_video.mp4'" > concat_full.txt
echo "file 'loop_video.mp4'" >> concat_full.txt
ffmpeg -y -f concat -safe 0 -i concat_full.txt -c copy full_video_noaudio.mp4

# ---- ⑥BGMをループさせて全体の尺に合わせ、導入部の間は無音(効果音は次フェーズで対応)、
#      ループ部分開始でBGMをフェードイン ----
ffmpeg -y -stream_loop -1 -i bgm.mp3 -t "$TOTAL_DURATION" \
  -af "afade=t=in:st=${INTRO_DURATION}:d=3" \
  -c:a aac full_audio.aac

# ---- ⑦映像と音声を結合 ----
ffmpeg -y -i full_video_noaudio.mp4 -i full_audio.aac \
  -map 0:v -map 1:a -c:v copy -c:a aac -shortest "$OUTPUT_FILE"

echo "=== レンダリング完了: $OUTPUT_FILE ==="
