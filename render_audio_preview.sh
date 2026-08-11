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

# ---- ④音質を自動評価する(Meta Audiobox Aesthetics) ----
# 人間の聴取評価(MOS)と同等の精度が報告されている無料のオープンソースモデル。
# 参照音源なしで、その音単体の品質を4つの軸で採点する。
#
#   CE (Content Enjoyment)   : 聴いていて楽しいか
#   CU (Content Usefulness)  : 素材としての有用性
#   PC (Production Complexity): 制作の複雑さ・作り込み
#   PQ (Production Quality)  : 音質そのもの
#
# ミックス版とBGM単体を比較すれば、効果音を足したことで良くなったかが数値で分かる。
echo "音質を評価します(Meta Audiobox Aesthetics)..."

# 評価にはwav形式が扱いやすいので変換する
ffmpeg -y -i audio_preview.mp3 -c:a pcm_s16le eval_mixed.wav 2>/dev/null
ffmpeg -y -i audio_preview_bgm_only.mp3 -c:a pcm_s16le eval_bgm.wav 2>/dev/null

cat > eval_input.jsonl << 'JSONL'
{"path":"eval_mixed.wav"}
{"path":"eval_bgm.wav"}
JSONL

# 評価に失敗しても音声ファイル自体は完成しているので、処理は止めない
if audio-aes eval_input.jsonl --batch-size 2 > eval_output.jsonl 2>eval_error.log; then
  echo "--- 音質スコア ---"
  cat eval_output.jsonl

  # 1行目=ミックス版、2行目=BGM単体。読みやすい形に整形して保存する
  python3 - << 'PYEOF' > score_summary.txt
import json

labels = ['ミックス版(効果音+BGM)', 'BGM単体']
axes = {'CE': '聴いていて楽しいか', 'CU': '素材としての有用性',
        'PC': '作り込みの複雑さ', 'PQ': '音質そのもの'}

try:
    with open('eval_output.jsonl') as f:
        rows = [json.loads(line) for line in f if line.strip()]
    for label, row in zip(labels, rows):
        print(f'【{label}】')
        for key, desc in axes.items():
            if key in row:
                print(f'  {key} ({desc}): {row[key]:.2f}')
        print()
    if len(rows) >= 2 and 'CE' in rows[0] and 'CE' in rows[1]:
        diff = rows[0]['CE'] - rows[1]['CE']
        if diff > 0.1:
            print(f'→ 効果音を足したことでスコアが上がっています (CE +{diff:.2f})')
        elif diff < -0.1:
            print(f'→ 効果音を足すとスコアが下がっています (CE {diff:.2f})')
        else:
            print('→ 効果音の有無でスコアはほぼ変わりません')
    print()
    print('※各軸は10点満点。人間の聴取評価と同等の精度が報告されている指標です')
except Exception as e:
    print('スコアの整形に失敗しました:', e)
PYEOF

  cat score_summary.txt
  echo "------------------"
else
  echo "音質評価をスキップしました(音声ファイルは正常に作成されています)"
  cat eval_error.log 2>/dev/null | tail -5
  echo "音質評価は実行されませんでした" > score_summary.txt
fi

rm -f eval_mixed.wav eval_bgm.wav

echo "=== 完成しました ==="
ls -la audio_preview*.mp3
