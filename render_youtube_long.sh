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
#      クロスフェードで各境目が重なるため、その分を上乗せしておかないと最終尺が足りなくなる
#
#      境目ごとに変化の速さを変える:
#        slow(12秒) = 天候の変化、自然光の移り変わり、遠景の町明かりが徐々に灯る
#                     → 長くかけることで「いつの間にか絵が変わっていた」体験になる
#        fast(1.5秒) = 手前の単一光源が点く/消える(部屋のランプ、暖炉に火が点く瞬間)
#                     → 現実には一瞬なので、ゆっくり変わるとかえって不自然
XFADE_SLOW=12
XFADE_FAST=1.5

# TRANSITIONS環境変数(例: "slow,slow,fast,slow,slow")を配列にする
# 指定がない場合は全てslowとして扱う
IFS=',' read -ra TRANSITION_ARR <<< "${TRANSITIONS:-}"

# 各境目のクロスフェード秒数を決める
XFADE_DURATIONS=()
BOUNDARY_COUNT=$((CLIP_COUNT - 1))
for ((b=0; b<BOUNDARY_COUNT; b++)); do
  if [ "${TRANSITION_ARR[$b]:-slow}" = "fast" ]; then
    XFADE_DURATIONS+=("$XFADE_FAST")
  else
    XFADE_DURATIONS+=("$XFADE_SLOW")
  fi
done
echo "境目ごとの変化速度: ${XFADE_DURATIONS[*]}"

# クロスフェードで重なる合計秒数を求める
OVERLAP_TOTAL=0
for d in "${XFADE_DURATIONS[@]}"; do
  OVERLAP_TOTAL=$(awk "BEGIN{print $OVERLAP_TOTAL + $d}")
done

LOOP_DURATION=$((TOTAL_DURATION - INTRO_DURATION))
STAGE_DURATION=$(awk "BEGIN{printf \"%d\", ($LOOP_DURATION + $OVERLAP_TOTAL) / $CLIP_COUNT}")
echo "ループ部分: ${LOOP_DURATION}秒 / 1段階あたり: ${STAGE_DURATION}秒 (重なり合計${OVERLAP_TOTAL}秒を上乗せ済み)"

# ---- ③各段階の短い動画クリップを、STAGE_DURATION秒になるまでループ再生する ----
#      (静止画ではなく実際に動いている数秒のクリップをループさせることで、常に動いて見える)
for i in "${!STAGE_CLIP_URLS[@]}"; do
  ffmpeg -y -stream_loop -1 -i "stage_clip_$i.mp4" -t "$STAGE_DURATION" \
    -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2" \
    -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -r 30 -an "stage_$i.mp4"
done

# ---- ④ループ部分の段階動画を、クロスフェードでつなげる ----
#      単純に連結すると段階の切り替わりで画がジャンプして「ブツ切り」に見えるため、
#      境目を数秒かけて溶かし込むことで、天候が連続的に変化しているように見せる

if [ "$CLIP_COUNT" -le 1 ]; then
  # 段階が1つしかない場合はそのまま使う
  cp stage_0.mp4 loop_video.mp4
else
  # xfadeは2本ずつしか処理できないため、先頭から順に1本ずつ溶かし込んでいく
  cp stage_0.mp4 merged.mp4
  MERGED_DURATION="$STAGE_DURATION"

  for ((i=1; i<CLIP_COUNT; i++)); do
    # この境目のクロスフェード秒数(slow/fastで変わる)
    XF="${XFADE_DURATIONS[$((i-1))]}"
    # これまで結合した映像の、末尾XF秒前から重ね始める
    OFFSET=$(awk "BEGIN{print $MERGED_DURATION - $XF}")
    echo "段階$((i+1))/${CLIP_COUNT} をクロスフェード${XF}秒で結合します(offset: ${OFFSET}秒)"

    ffmpeg -y -i merged.mp4 -i "stage_$i.mp4" \
      -filter_complex "[0:v][1:v]xfade=transition=fade:duration=${XF}:offset=${OFFSET}[v]" \
      -map "[v]" -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -r 30 -an merged_next.mp4

    mv merged_next.mp4 merged.mp4
    # クロスフェードで重なった分だけ全体の尺が縮む
    MERGED_DURATION=$(awk "BEGIN{print $MERGED_DURATION + $STAGE_DURATION - $XF}")
  done

  mv merged.mp4 loop_video.mp4
fi

echo "ループ部分の結合が完了しました"

# ---- ⑤導入部とループ部分をつなげる(映像のみ、音声は後で合成) ----
#      導入動画にも音声トラックがある可能性があるため、映像のみ抽出してから結合する
#      ※ここはクロスフェードしない。導入部の最終フレームがstage1画像そのものなので、
#        単純に連結するだけで自然につながる(溶かすとかえって不自然になる)
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
  echo "効果音+BGMの合成を行います(帯域を棲み分けてミックス)..."

  # 【設計根拠】
  # 雨や風などの自然音はピンクノイズ特性を持ち、低域(特に500Hz以下)にエネルギーが集中している。
  # そのためBGMの低域をそのまま重ねると両方が濁る。
  # BGM側は250Hz以下をハイパスで削り、中高域だけを残して環境音の上に浮かせる。
  # 環境音側は低域をそのまま活かし、耳につきやすい高域だけ軽く抑える。

  # BGM: ループしてINTRO_DURATION秒後からフェードイン
  #   highpass=f=250 で低域を環境音に明け渡す
  ffmpeg -y -stream_loop -1 -i bgm.mp3 -t "$TOTAL_DURATION" \
    -af "highpass=f=250,afade=t=in:st=${INTRO_DURATION}:d=3,volume=0.8" \
    -c:a pcm_s16le bgm_full.wav

  # 効果音: ループして全体に流す
  #   導入部は0.9音量(メイン)、ループ開始から0.3音量へフェードダウン
  #   lowpass=f=8000 で耳につきやすい超高域を軽く抑え、低〜中域の自然な厚みは残す
  ffmpeg -y -stream_loop -1 -i ambient.mp3 -t "$TOTAL_DURATION" \
    -af "lowpass=f=8000,volume=0.9,afade=t=out:st=${INTRO_DURATION}:d=5[fade_out_ch];[fade_out_ch]volume=0.3" \
    -c:a pcm_s16le ambient_full.wav 2>/dev/null || \
  ffmpeg -y -stream_loop -1 -i ambient.mp3 -t "$TOTAL_DURATION" \
    -af "lowpass=f=8000,volume=0.3" \
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
