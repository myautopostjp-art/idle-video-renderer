#!/bin/bash
set -e

# ============================================================
# BGM + 効果音のミックス試聴版を作る
#
# 1時間の動画を作らずに音の相性だけを確認するためのスクリプト。
# render_youtube_long.sh のループ部分と同じEQ・音量・残響設定を使うので、
# ここで良ければ本番でも同じ聴こえ方になる。
# ============================================================

BGM_URL="$1"
AMBIENT_URL="$2"
PARTICLE_KEY="$3"
DURATION="${4:-120}"

echo "=== 音声ミックス試聴版の作成 ==="
echo "particleKey: $PARTICLE_KEY / 長さ: ${DURATION}秒"

# ---- ①素材のダウンロード ----
echo "BGMをダウンロードします..."
curl -sL "$BGM_URL" -o bgm.mp3
echo "効果音をダウンロードします..."
curl -sL "$AMBIENT_URL" -o ambient.mp3

# ---- ②本番と同じ設定でミックス ----
# 【設計根拠】render_youtube_long.sh と同一の設定
#   雨や風などの自然音はピンクノイズ特性を持ち、低域にエネルギーが集中している。
#   BGM側は250Hz以下を削って環境音に明け渡し、中高域に居場所を作る。
#   環境音側は高域を落として奥に引っ込め、BGMの前に出させない。
#   両方に同系統の残響を足し、同じ空間で鳴っているように馴染ませる。

echo "BGMを処理します(highpass 250Hz + 残響)..."
ffmpeg -y -stream_loop -1 -i bgm.mp3 -t "$DURATION" \
  -af "highpass=f=250,aecho=0.8:0.9:50:0.2,afade=t=in:st=0:d=3,volume=0.8" \
  -c:a pcm_s16le bgm_full.wav

echo "効果音を処理します(lowpass 4000Hz + 残響)..."
ffmpeg -y -stream_loop -1 -i ambient.mp3 -t "$DURATION" \
  -af "lowpass=f=4000,aecho=0.8:0.85:60:0.25,volume=0.25" \
  -c:a pcm_s16le ambient_full.wav

echo "ミックスします(+ 軽いコンプレッション)..."
ffmpeg -y -i bgm_full.wav -i ambient_full.wav \
  -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0[mixed];[mixed]acompressor=threshold=0.15:ratio=3:attack=200:release=1000[aout]" \
  -map "[aout]" -c:a libmp3lame -b:a 192k "audio_preview.mp3"

# ---- ③比較用にBGM単体も書き出す ----
# 効果音を足したことで良くなったのか悪くなったのか判断できるようにする
echo "比較用にBGM単体も書き出します..."
ffmpeg -y -stream_loop -1 -i bgm.mp3 -t "$DURATION" \
  -af "afade=t=in:st=0:d=3" \
  -c:a libmp3lame -b:a 192k "audio_preview_bgm_only.mp3"

echo "=== 完成しました ==="
ls -la audio_preview*.mp3
