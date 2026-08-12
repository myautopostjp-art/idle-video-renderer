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
# 新方式では境目の映像は前後の段階から半分ずつ供出されるため、
# 全体としては境目の秒数分だけ尺が縮む
OVERLAP_TOTAL=0
for d in "${XFADE_DURATIONS[@]}"; do
  OVERLAP_TOTAL=$(awk "BEGIN{print $OVERLAP_TOTAL + $d}")
done

LOOP_DURATION=$((TOTAL_DURATION - INTRO_DURATION))
STAGE_DURATION=$(awk "BEGIN{printf \"%d\", ($LOOP_DURATION + $OVERLAP_TOTAL) / $CLIP_COUNT}")
echo "ループ部分: ${LOOP_DURATION}秒 / 1段階あたり: ${STAGE_DURATION}秒 (重なり合計${OVERLAP_TOTAL}秒を上乗せ済み)"

# ---- ③各段階の短い動画クリップを、必要な長さまでループ再生する ----
#      (静止画ではなく実際に動いている数秒のクリップをループさせることで、常に動いて見える)
#
#      【処理設計】
#      以前は「10分の動画に次の10分を溶かし込む」処理を5回繰り返していたが、
#      回を追うごとに再エンコード対象が長くなり(最後は50分)、1時間の制限を超えていた。
#
#      そこで「境目の十数秒だけをクロスフェードで作り、本体はそのまま連結する」方式に変更する。
#      再エンコードが必要なのは境目の数十秒分だけになるため、処理時間が劇的に短くなる。
#
#        [段階1本体][境目1][段階2本体][境目2][段階3本体]...
#                    ↑ここだけxfadeで作る

# 各段階について、本体部分の長さを求める
#   先頭の段階  : 後ろの境目にだけ尺を取られる
#   中間の段階  : 前後の境目に尺を取られる
#   最後の段階  : 前の境目にだけ尺を取られる
echo "各段階の動画を用意します..."
for ((i=0; i<CLIP_COUNT; i++)); do
  BEFORE=0
  AFTER=0
  [ "$i" -gt 0 ] && BEFORE="${XFADE_DURATIONS[$((i-1))]}"
  [ "$i" -lt "$((CLIP_COUNT-1))" ] && AFTER="${XFADE_DURATIONS[$i]}"

  # この段階が必要とする総尺(本体 + 前後の境目に供出する分)
  ffmpeg -y -stream_loop -1 -i "stage_clip_$i.mp4" -t "$STAGE_DURATION" \
    -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2" \
    -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -r 30 -an "stage_$i.mp4" 2>/dev/null

  # 境目に使う部分を切り出す
  #   前の境目用: この段階の先頭BEFORE秒
  #   後の境目用: この段階の末尾AFTER秒
  if [ "$(awk "BEGIN{print ($AFTER > 0)}")" = "1" ]; then
    TAIL_START=$(awk "BEGIN{print $STAGE_DURATION - $AFTER}")
    ffmpeg -y -ss "$TAIL_START" -i "stage_$i.mp4" -t "$AFTER" \
      -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -r 30 -an "tail_$i.mp4" 2>/dev/null
  fi
  if [ "$(awk "BEGIN{print ($BEFORE > 0)}")" = "1" ]; then
    ffmpeg -y -i "stage_$i.mp4" -t "$BEFORE" \
      -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -r 30 -an "head_$i.mp4" 2>/dev/null
  fi

  # 本体部分(境目に供出した分を除いた中間部分)を切り出す
  BODY_DURATION=$(awk "BEGIN{print $STAGE_DURATION - $BEFORE - $AFTER}")
  ffmpeg -y -ss "$BEFORE" -i "stage_$i.mp4" -t "$BODY_DURATION" \
    -c copy "body_$i.mp4" 2>/dev/null
done

# ---- ④境目だけクロスフェードを作り、本体と交互に連結する ----
echo "境目のクロスフェードを作成します..."
> concat_loop.txt
for ((i=0; i<CLIP_COUNT; i++)); do
  echo "file 'body_$i.mp4'" >> concat_loop.txt

  # 最後の段階でなければ、次の段階との境目を作る
  if [ "$i" -lt "$((CLIP_COUNT-1))" ]; then
    XF="${XFADE_DURATIONS[$i]}"
    echo "  段階$((i+1))→$((i+2)): ${XF}秒のクロスフェード"
    ffmpeg -y -i "tail_$i.mp4" -i "head_$((i+1)).mp4" \
      -filter_complex "[0:v][1:v]xfade=transition=fade:duration=${XF}:offset=0[v]" \
      -map "[v]" -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -r 30 -an "xfade_$i.mp4" 2>/dev/null
    echo "file 'xfade_$i.mp4'" >> concat_loop.txt
  fi
done

# 本体とクロスフェードを順に連結する(再エンコードなし = 高速)
ffmpeg -y -f concat -safe 0 -i concat_loop.txt -c copy loop_video.mp4

echo "ループ部分の結合が完了しました"

# ---- ⑤導入部とループ部分をつなげる(映像のみ、音声は後で合成) ----
#      ※ここはクロスフェードしない。導入部の最終フレームがstage1画像そのものなので、
#        単純に連結するだけで自然につながる(溶かすとかえって不自然になる)
#
#      【重要】導入部とループ部分で解像度やフレームレートが違うと、
#      連結した動画の途中で画角が変わってしまう。
#      以前は導入部を -c:v copy でそのまま使っていたためこの問題が起きていた。
#      ここでループ部分と同じ 1920x1080 / 30fps に揃えてから連結する。
echo "導入部をループ部分と同じ規格に揃えます..."
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate \
  -of default=nw=1 intro_video.mp4 || true

ffmpeg -y -i intro_video.mp4 -an \
  -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=30" \
  -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p intro_video_noaudio.mp4

echo "file 'intro_video_noaudio.mp4'" > concat_full.txt
echo "file 'loop_video.mp4'" >> concat_full.txt
ffmpeg -y -f concat -safe 0 -i concat_full.txt -c copy full_video_noaudio.mp4

# 念のため、完成した映像の解像度が一貫しているか確認する
echo "--- 完成した映像の情報 ---"
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate,duration \
  -of default=nw=1 full_video_noaudio.mp4 || true

# ---- ⑥音声合成 ----
# 設計:
#   「室内を見回し、開いた戸を抜けてテラスへ出る」という導入部の流れに合わせる。
#
#   0秒〜         : 効果音のみ。まだ室内にいるので、外の音は控えめに聴こえている
#   BGM_FADE_START: BGMが立ち上がり始める(戸へ向かって歩き出すあたり)
#   INTRO_DURATION: 外に出た時点では音楽が満ちており、景色と一緒に音楽を味わえる
#
#   完全な無音から始めると唐突なので、冒頭から効果音を敷いておく。
#   効果音は導入部では強め(0.9)、ループ部分に入ったら控えめ(0.25)に下げてBGMを立たせる。

# BGMのフェードインを始める時刻
#
# 外に出て景色が開ける瞬間に音楽が満ちている状態にしたいので、
# 導入部の終わる少し前から立ち上げ始め、終わりまでに全開になるよう逆算する。
#   導入部20秒の場合: 13秒から立ち上がり、18秒で全開、20秒で外に出る
BGM_FADE_DURATION=5
BGM_FADE_START=$(awk "BEGIN{v=$INTRO_DURATION-7; if(v<0) v=0; print v}")
echo "BGMフェードイン: ${BGM_FADE_START}秒から${BGM_FADE_DURATION}秒かけて立ち上げ(導入部は${INTRO_DURATION}秒)"

# 効果音あり・なしで処理を分岐する
if [ "$HAS_AMBIENT" = true ]; then
  echo "効果音+BGMの合成を行います(帯域を棲み分けてミックス)..."

  # 【設計根拠】
  # 雨や風などの自然音はピンクノイズ特性を持ち、低域(特に500Hz以下)にエネルギーが集中している。
  # そのためBGMの低域をそのまま重ねると両方が濁る。
  # BGM側は250Hz以下をハイパスで削り、中高域だけを残して環境音の上に浮かせる。
  #
  # 一方で環境音(特に風)は中高域まで帯域が広く、BGMの居場所を奪って
  # 「2つの音が別々に鳴っている」状態になりやすい。
  # そこで環境音側の高域を大きく削り、遠景に退かせることで音楽と溶け合わせる。

  # 【設計】BGMと環境音が「別々に鳴っている」状態を避けるための処理
  #
  # 環境音は種類によって周波数特性が違うため、EQの当て方を変える。
  #
  #  ・雨や波: 低域(〜250Hz)にエネルギーが集中したピンクノイズ特性。
  #           BGM側の低域を削って場所を譲り、中高域だけを残して上に浮かせる。
  #
  #  ・湯の音: 中域(250Hz〜4kHz)が主体で低域は薄い。
  #           BGM側の低域を削る必要はなく、むしろ低〜中低域を残して土台にする。
  #           代わりに水の弾ける音が聴こえるよう、BGMの2〜5kHzを少し下げる。
  #           環境音側は80Hz以下を削り、BGMのパッドをクリアに響かせる。

  case "$PARTICLE_KEY" in
    onsen)
      # 湯の音: BGMは低域を残し、水の弾ける帯域(2〜5kHz)だけ軽く譲る
      BGM_EQ="equalizer=f=3000:width_type=o:width=1.5:g=-2,aecho=0.8:0.9:50:0.2"
      # 環境音: 低域を削ってBGMの土台を邪魔しない。高域は残して水の質感を活かす
      AMBIENT_EQ="highpass=f=80,lowpass=f=8000,aecho=0.8:0.85:60:0.25"
      # 湯の音は雨より音量が小さいので、少し上げる
      AMBIENT_LOOP_VOLUME=0.32
      ;;
    *)
      # 雨・波など低域の厚い環境音: BGMの低域を明け渡す
      BGM_EQ="highpass=f=250,aecho=0.8:0.9:50:0.2"
      AMBIENT_EQ="lowpass=f=4000,aecho=0.8:0.85:60:0.25"
      AMBIENT_LOOP_VOLUME=0.25
      ;;
  esac
  echo "音声EQ: particleKey=${PARTICLE_KEY:-未指定} / 環境音のループ音量=${AMBIENT_LOOP_VOLUME}"

  # BGM: ループして、戸へ向かうあたりからフェードイン
  ffmpeg -y -stream_loop -1 -i bgm.mp3 -t "$TOTAL_DURATION" \
    -af "${BGM_EQ},afade=t=in:st=${BGM_FADE_START}:d=${BGM_FADE_DURATION},volume=0.8" \
    -c:a pcm_s16le bgm_full.wav

  # 効果音: ループして全体に流す
  #   導入部は0.9音量(室内から外の気配を感じさせる)、ループ開始から通常音量へフェードダウン
  ffmpeg -y -stream_loop -1 -i ambient.mp3 -t "$TOTAL_DURATION" \
    -af "${AMBIENT_EQ},volume=0.9,afade=t=out:st=${INTRO_DURATION}:d=5[fade_out_ch];[fade_out_ch]volume=${AMBIENT_LOOP_VOLUME}" \
    -c:a pcm_s16le ambient_full.wav 2>/dev/null || \
  ffmpeg -y -stream_loop -1 -i ambient.mp3 -t "$TOTAL_DURATION" \
    -af "${AMBIENT_EQ},volume=${AMBIENT_LOOP_VOLUME}" \
    -c:a pcm_s16le ambient_full.wav

  # BGM + 効果音をミックス
  #   ミックス後に軽いコンプレッションをかけ、2つの音を同じダイナミクスにまとめる
  #   (別々に鳴っている感じを減らし、ひとつの音像として聴かせる)
  ffmpeg -y -i bgm_full.wav -i ambient_full.wav \
    -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0[mixed];[mixed]acompressor=threshold=0.15:ratio=3:attack=200:release=1000[aout]" \
    -map "[aout]" -c:a aac full_audio.aac

else
  echo "BGMのみで音声合成を行います..."

  # BGM: ループして、窓へ向かうあたりからフェードイン
  ffmpeg -y -stream_loop -1 -i bgm.mp3 -t "$TOTAL_DURATION" \
    -af "afade=t=in:st=${BGM_FADE_START}:d=${BGM_FADE_DURATION}" \
    -c:a aac full_audio.aac
fi

# ---- ⑦映像と音声を結合 ----
ffmpeg -y -i full_video_noaudio.mp4 -i full_audio.aac \
  -map 0:v -map 1:a -c:v copy -c:a aac -shortest "$OUTPUT_FILE"

echo "=== レンダリング完了: $OUTPUT_FILE ==="
