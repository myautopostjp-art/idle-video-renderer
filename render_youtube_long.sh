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

# 【画質とファイルサイズ】
# CRFは値が小さいほど高画質・大容量。放置動画は動きが穏やかなので23でも十分きれい。
# 1時間の動画はCRF20だと2GBを超えることがあり、GitHub Releaseの上限に引っかかる。
# 23にすると1GB前後に収まる。
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

CLIP_COUNT=${#STAGE_CLIP_URLS[@]}

# ループ用のクリップが1本もないと、後の尺計算でゼロ除算になってしまう。
# 原因が分かりにくいエラーで止まるのを避けるため、ここで明示的に知らせる。
if [ "$CLIP_COUNT" -eq 0 ]; then
  echo "エラー: ループ用の段階動画クリップが1本もありません"
  echo ""
  echo "ステップ①B(段階動画クリップの生成)が完了していない可能性があります。"
  echo "GASで checkYoutubeLongState を実行して状態を確認し、"
  echo "testYoutubeLongVideoStep1B でクリップを作ってから、もう一度お試しください。"
  exit 1
fi

echo "ループ用の段階動画クリップをダウンロード中...(${CLIP_COUNT}本)"
for i in "${!STAGE_CLIP_URLS[@]}"; do
  curl -L -s -o "stage_clip_raw_$i.mp4" "${STAGE_CLIP_URLS[$i]}"
done

# ---- ①-2 クリップのカメラ移動を打ち消す ----
#
# LTXはプロンプトで「カメラを固定せよ」と指示しても、
# ゆっくり左右にドリフトさせてしまうことがある。
# ループ動画では6秒ごとに位置が戻るため、この動きが強く目立つ。
#
# vidstab で移動量を検出し、逆方向にずらして打ち消す。
#   smoothing=0  … 平滑化せず、完全に固定する(手ぶれ補正ではなく静止が目的)
#   relative=1   … 前フレームからの相対移動として補正する(こちらの方が効果が高い)
#   zoom=8       … ずらした分の隙間を埋めるため、わずかに拡大する
#
# 情景の中の動き(湯気・水面・星の瞬き)は位置が変わらないので影響を受けない。
echo "クリップのカメラ移動を除去します..."
for ((i=0; i<CLIP_COUNT; i++)); do
  if ffmpeg -y -i "stage_clip_raw_$i.mp4" \
       -vf "vidstabdetect=shakiness=10:accuracy=15:stepsize=6:result=stab_$i.trf" \
       -f null - 2>/dev/null \
     && ffmpeg -y -i "stage_clip_raw_$i.mp4" \
       -vf "vidstabtransform=input=stab_$i.trf:smoothing=0:relative=1:optzoom=0:zoom=8:crop=black" \
       -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -an "stage_clip_$i.mp4" 2>/dev/null; then
    echo "  クリップ$((i+1)): 安定化しました"
  else
    # 安定化に失敗しても元のクリップで続行する
    cp "stage_clip_raw_$i.mp4" "stage_clip_$i.mp4"
    echo "  クリップ$((i+1)): 安定化をスキップしました(元の映像を使用)"
  fi
done

# ---- ①-3 クリップをシームレスループに加工する ----
#
# 6秒のクリップをそのまま繰り返すと、最後のフレームから最初のフレームへ
# 一瞬で切り替わるため、位置や湯気の形の差が「カクッ」という違和感になる。
#
# そこで末尾1秒と先頭1秒をクロスフェードで溶かし合わせ、
# 「終わりの画=始まりの画」となる5秒の完全ループを作る。
#
#   [1〜5秒の本体][末尾1秒が先頭1秒へ溶けていく]
#    → 継ぎ目が原理的に存在しなくなる
#
# 湯気・水面・星の瞬きは形の定まらない被写体なので、
# 1秒のディゾルブは自然な動きにしか見えない。
# カメラのドリフトが残っていても、跳ぶのではなく柔らかく溶けるため目立たない。
XFADE_LOOP=1
echo "クリップをシームレスループに加工します..."
for ((i=0; i<CLIP_COUNT; i++)); do
  CLIP_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "stage_clip_$i.mp4")
  BODY_END=$(awk "BEGIN{print $CLIP_DUR - $XFADE_LOOP}")

  if ffmpeg -y -i "stage_clip_$i.mp4" -filter_complex \
      "[0:v]trim=start=${XFADE_LOOP}:end=${BODY_END},setpts=PTS-STARTPTS[main];\
[0:v]trim=start=${BODY_END},setpts=PTS-STARTPTS[tail];\
[0:v]trim=start=0:end=${XFADE_LOOP},setpts=PTS-STARTPTS[head];\
[tail][head]xfade=transition=fade:duration=${XFADE_LOOP}:offset=0[wrap];\
[main][wrap]concat=n=2:v=1[out]" \
      -map "[out]" -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -r 30 -an "stage_loop_$i.mp4" 2>/dev/null; then
    LOOP_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "stage_loop_$i.mp4")
    echo "  クリップ$((i+1)): シームレスループ化しました(${CLIP_DUR}秒 → ${LOOP_DUR}秒)"
    mv "stage_loop_$i.mp4" "stage_clip_$i.mp4"
  else
    echo "  クリップ$((i+1)): 加工に失敗したため、そのまま使います"
  fi
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
    -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -r 30 -an "stage_$i.mp4" 2>/dev/null

  # 境目に使う部分を切り出す
  #   前の境目用: この段階の先頭BEFORE秒
  #   後の境目用: この段階の末尾AFTER秒
  if [ "$(awk "BEGIN{print ($AFTER > 0)}")" = "1" ]; then
    TAIL_START=$(awk "BEGIN{print $STAGE_DURATION - $AFTER}")
    ffmpeg -y -ss "$TAIL_START" -i "stage_$i.mp4" -t "$AFTER" \
      -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -r 30 -an "tail_$i.mp4" 2>/dev/null
  fi
  if [ "$(awk "BEGIN{print ($BEFORE > 0)}")" = "1" ]; then
    ffmpeg -y -i "stage_$i.mp4" -t "$BEFORE" \
      -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -r 30 -an "head_$i.mp4" 2>/dev/null
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
      -map "[v]" -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -r 30 -an "xfade_$i.mp4" 2>/dev/null
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
  -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p intro_video_noaudio.mp4

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
      # 環境音: 低域を削ってBGMの土台を邪魔しない
      #   loudnorm で音圧を一定に揃えてから音量を決める。
      #   生成される効果音は素材ごとに音量がばらつくため、これがないと
      #   「作った音によっては全く聴こえない」という事故が起きる。
      #   aecho の遅延を長め(120ms)にして、岩に囲まれた露天風呂の広がりを出す
      #   (60msだと浴室のような狭い響きになる)
      #
      #   lowpass は距離感の表現で使うため、ここでは分けて持っておく
      AMBIENT_EQ_BASE="highpass=f=80,loudnorm=I=-20:TP=-2,aecho=0.8:0.88:120:0.35"
      AMBIENT_LOWPASS=8000
      # 湯の音は雨のように鳴り続ける音ではないため、しっかり上げる
      AMBIENT_LOOP_VOLUME=0.40
      ;;
    *)
      # 雨・波など低域の厚い環境音: BGMの低域を明け渡す
      BGM_EQ="highpass=f=250,aecho=0.8:0.9:50:0.2"
      AMBIENT_EQ_BASE="loudnorm=I=-20:TP=-2,aecho=0.8:0.85:60:0.25"
      AMBIENT_LOWPASS=4000
      AMBIENT_LOOP_VOLUME=0.3
      ;;
  esac
  echo "音声EQ: particleKey=${PARTICLE_KEY:-未指定} / 環境音のループ音量=${AMBIENT_LOOP_VOLUME}"

  # BGM: ループして、戸へ向かうあたりからフェードイン
  ffmpeg -y -stream_loop -1 -i bgm.mp3 -t "$TOTAL_DURATION" \
    -af "${BGM_EQ},afade=t=in:st=${BGM_FADE_START}:d=${BGM_FADE_DURATION},volume=0.8" \
    -c:a pcm_s16le bgm_full.wav

  # 効果音: 導入部で「遠くから近づいてくる」ように変化させる
  #
  # 【設計】
  # カメラは室内の奥から歩き出し、戸を抜けて湯船のそばへ出る。
  # それなのに最初から音が大きいと、距離感が映像と食い違ってしまう。
  #
  # 遠くの音は「小さい」だけでなく「高域が減衰してこもって聴こえる」。
  # 空気や壁が高い周波数から先に吸収するためで、音量だけを絞っても
  # 「近くで小さく鳴っている音」にしか聴こえない。
  #
  # 【実装】
  # 「遠い音」と「近い音」を別々に作り、導入部の長さをかけて入れ替える。
  #   遠い音 … 1.2kHz以上を落としてこもらせ、音量も小さく
  #   近い音 … 8kHzまで開けて水の弾ける音まで聴こえる、通常音量
  # (volumeやlowpassに時間の式を書く方法もあるが、lowpassは動的な
  #  周波数指定に対応していないため、2つ作って混ぜる方式にしている)
  DIST_FAR_VOL=$(awk "BEGIN{printf \"%.3f\", $AMBIENT_LOOP_VOLUME * 0.28}")
  echo "効果音の距離変化: 遠(${DIST_FAR_VOL}/こもり) → ${INTRO_DURATION}秒 → 近(${AMBIENT_LOOP_VOLUME}/開け)"

  # 遠くで聴こえている状態
  ffmpeg -y -stream_loop -1 -i ambient.mp3 -t "$TOTAL_DURATION" \
    -af "${AMBIENT_EQ_BASE},lowpass=f=1200,volume=${DIST_FAR_VOL}" \
    -c:a pcm_s16le ambient_far.wav

  # すぐそばで聴こえている状態
  ffmpeg -y -stream_loop -1 -i ambient.mp3 -t "$TOTAL_DURATION" \
    -af "${AMBIENT_EQ_BASE},lowpass=f=${AMBIENT_LOWPASS},volume=${AMBIENT_LOOP_VOLUME}" \
    -c:a pcm_s16le ambient_near.wav

  # 導入部をかけて遠い音から近い音へ入れ替える
  if ffmpeg -y -i ambient_far.wav -i ambient_near.wav -filter_complex \
      "[0:a]afade=t=out:st=0:d=${INTRO_DURATION}:curve=tri[far];\
[1:a]afade=t=in:st=0:d=${INTRO_DURATION}:curve=tri[near];\
[far][near]amix=inputs=2:duration=longest:normalize=0[out]" \
      -map "[out]" -c:a pcm_s16le ambient_full.wav 2>/dev/null; then
    echo "効果音に距離変化を適用しました"
    rm -f ambient_far.wav ambient_near.wav
  else
    # 失敗した場合は一定音量で処理する
    echo "距離変化の適用に失敗したため、一定音量で処理します"
    ffmpeg -y -stream_loop -1 -i ambient.mp3 -t "$TOTAL_DURATION" \
      -af "${AMBIENT_EQ_BASE},lowpass=f=${AMBIENT_LOWPASS},volume=${AMBIENT_LOOP_VOLUME}" \
      -c:a pcm_s16le ambient_full.wav
  fi

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
