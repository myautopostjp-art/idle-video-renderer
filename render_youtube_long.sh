#!/bin/bash
# =====================================================
# YouTube長尺BGM動画レンダリングスクリプト(高品質版)
# 配置場所: リポジトリの render_youtube_long.sh
#
# 構成: 導入部(LTX動画、動きあり) + ループ部分(各段階が短い動画クリップのループ、常に動いている)
# 引数: $1=導入動画URL $2=BGM URL $3=総尺(秒) $4=導入部秒数 $5=出力ファイル名 $6以降=ループ用の段階動画クリップURL(6本)
# 環境変数: AMBIENT_SOUND_URL=効果音URL(省略可。省略時はBGMのみ)
# =====================================================
set -e
INTRO_VIDEO_URL="$1"
BGM_URL="$2"
TOTAL_DURATION="$3"
INTRO_DURATION="$4"
OUTPUT_FILE="$5"
shift 5
STAGE_CLIP_URLS=("$@")
echo "=== YouTube長尺動画レンダリング開始(高品質版) ==="
echo "導入動画: $INTRO_VIDEO_URL"
echo "BGM: $BGM_URL"
echo "総尺: ${TOTAL_DURATION}秒 / 導入部: ${INTRO_DURATION}秒"
echo "ループ段階クリップ数: ${#STAGE_CLIP_URLS[@]}"
echo "効果音: ${AMBIENT_SOUND_URL:-なし}"

# ---- ①素材のダウンロード ----
echo "導入動画をダウンロード中..."
curl -L -s -o intro_video.mp4 "$INTRO_VIDEO_URL"
echo "BGMをダウンロード中..."
curl -L -s -o bgm.mp3 "$BGM_URL"

# 効果音のダウンロード(URLが指定されている場合のみ)
HAS_AMBIENT=false
if [ -n "$AMBIENT_SOUND_URL" ] && [ "$AMBIENT_SOUND_URL" != "none" ]; then
  echo "効果音をダウンロード中..."
  curl -L -s -o ambient.mp3 "$AMBIENT_SOUND_URL"
  HAS_AMBIENT=true
fi

echo "ループ用の段階動画クリップをダウンロード中..."
CLIP_COUNT=${#STAGE_CLIP_URLS[@]}
for i in "${!STAGE_CLIP_URLS[@]}"; do
  curl -L -s -o "stage_clip_$i.mp4" "${STAGE_CLIP_URLS[$i]}"
done

# ---- ②ループ部分の尺を計算 ----
LOOP_DURATION=$((TOTAL_DURATION - INTRO_DURATION))
STAGE_DURATION=$((LOOP_DURATION / CLIP_COUNT))
echo "ループ部分: ${LOOP_DURATION}秒 / 1段階あたり: ${STAGE_DURATION}秒"

# ---- ③各段階の短い動画クリップを、STAGE_DURATION秒になるまでループ再生する ----
#      (静止画ではなく実際に動いている数秒のクリップをループさせることで、常に動いて見える)
for i in "${!STAGE_CLIP_URLS[@]}"; do
  ffmpeg -y -stream_loop -1 -i "stage_clip_$i.mp4" -t "$STAGE_DURATION" \
    -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2" \
    -c:v libx264 -pix_fmt yuv420p -r 30 -an "stage_$i.mp4"
done

# ---- ④ループ部分の段階動画を全部つなげる ----
> concat_list.txt
for i in "${!STAGE_CLIP_URLS[@]}"; do
  echo "file 'stage_$i.mp4'" >> concat_list.txt
done
ffmpeg -y -f concat -safe 0 -i concat_list.txt -c copy loop_video.mp4

# ---- ⑤導入部とループ部分をつなげる(映像のみ、音声は後で合成) ----
#      導入動画にも音声トラックがある可能性があるため、映像のみ抽出してから結合する
ffmpeg -y -i intro_video.mp4 -an -c:v copy intro_video_noaudio.mp4 2>/dev/null || cp intro_video.mp4 intro_video_noaudio.mp4
echo "file 'intro_video_noaudio.mp4'" > concat_full.txt
echo "file 'loop_video.mp4'" >> concat_full.txt
ffmpeg -y -f concat -safe 0 -i concat_full.txt -c copy full_video_noaudio.mp4

# ---- ⑥音声合成 ----
# 設計:
#   導入部(0〜INTRO_DURATION秒): 効果音のみ(BGMは無音)
#   ループ部分開始時点(INTRO_DURATION秒〜): BGMがフェードイン、効果音は控えめ音量で継続
#
# 効果音あり・なしで処理を分岐する
if [ "$HAS_AMBIENT" = true ]; then
  echo "効果音+BGMの合成を行います..."

  # BGM: ループしてINTRO_DURATION秒後からフェードイン、ループ部分は0.75音量
  ffmpeg -y -stream_loop -1 -i bgm.mp3 -t "$TOTAL_DURATION" \
    -af "afade=t=in:st=${INTRO_DURATION}:d=3,volume=0.75" \
    -c:a pcm_s16le bgm_full.wav

  # 効果音: ループして全体に流す
  #   導入部は0.9音量(メイン)、ループ開始(INTRO_DURATION秒)から0.3音量へフェードダウン(5秒かけて)
  ffmpeg -y -stream_loop -1 -i ambient.mp3 -t "$TOTAL_DURATION" \
    -af "volume=0.9,afade=t=out:st=${INTRO_DURATION}:d=5[fade_out_ch];[fade_out_ch]volume=0.3" \
    -c:a pcm_s16le ambient_full.wav 2>/dev/null || \
  ffmpeg -y -stream_loop -1 -i ambient.mp3 -t "$TOTAL_DURATION" \
    -af "volume=0.35" \
    -c:a pcm_s16le ambient_full.wav

  # BGM + 効果音をミックス
  ffmpeg -y -i bgm_full.wav -i ambient_full.wav \
    -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0[aout]" \
    -map "[aout]" -c:a aac full_audio.aac

else
  echo "BGMのみで音声合成を行います..."

  # BGM: ループしてINTRO_DURATION秒後からフェードイン
  ffmpeg -y -stream_loop -1 -i bgm.mp3 -t "$TOTAL_DURATION" \
    -af "afade=t=in:st=${INTRO_DURATION}:d=3" \
    -c:a aac full_audio.aac
fi

# ---- ⑦映像と音声を結合 ----
ffmpeg -y -i full_video_noaudio.mp4 -i full_audio.aac \
  -map 0:v -map 1:a -c:v copy -c:a aac -shortest "$OUTPUT_FILE"

echo "=== レンダリング完了: $OUTPUT_FILE ==="
