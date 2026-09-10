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
SYNTH_TYPE="none"  # fireflies / petals / leaves のいずれか、または none
case "$RAIN_URL" in
  synthetic-fireflies) SYNTH_TYPE="fireflies"; echo "=== 蛍演出: ffmpegで直接生成します(外部素材不要) ===" ;;
  synthetic-petals)    SYNTH_TYPE="petals";    echo "=== 桜吹雪演出: ffmpegで直接生成します(外部素材不要) ===" ;;
  synthetic-leaves)    SYNTH_TYPE="leaves";     echo "=== 落ち葉演出: ffmpegで直接生成します(外部素材不要) ===" ;;
  none|"") ;;
  *)
    echo "=== 雨オーバーレイ素材ダウンロード ==="
    curl -L -o rain.mp4 "$RAIN_URL"
    if file rain.mp4 | grep -qi html; then
      echo "警告: 雨オーバーレイのダウンロードに失敗しました。雨演出なしで続行します"
    else
      USE_RAIN=true
    fi
    ;;
esac
USE_SYNTH=false
if [ "$SYNTH_TYPE" != "none" ]; then
  USE_SYNTH=true
fi

FONT="/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
# タイマーの色
#
# 【淡い黄のままにしている理由】
# 一度白(#FFFFFF)にしたが、情景の暖色(行灯・暖炉・夕焼け)と馴染む
# 淡い黄のほうが良いと判断して戻した。
# 縮小したときの読みやすさは、黒縁の太さで確保する。
TEXT_COLOR="#FFE9B3"
BORDER_COLOR="black"

# 画面に出す文字をタイマーだけにするか
#
# 【1にした理由】
# 上下に日本語の文字を焼き込んでいたが、焼き込んだ文字は翻訳されない。
# 8か国(米・英・独・日・韓・仏・墨・伯)を対象にする以上、
# 日本語が読めない視聴者には意味不明な文字が乗るだけになる。
# 数字は世界共通なので、タイマーだけなら誰にでも通じる。
#
# 説明文はTikTokが自動翻訳するので、伝えたいことはそちらに書く。
# 絵も隠れなくなる。
#
#   0 … 上下のテキストも出す(以前の動作)
#   1 … タイマーだけにする(現在)
TIMER_ONLY=1

# 入力オプション組み立て(画像N枚 + BGM1つ + 雨オーバーレイ(あれば))
INPUTS=()
for i in "${!IMAGE_URLS[@]}"; do
  INPUTS+=(-loop 1 -framerate 6 -t "$STAGE_SRC_SEC" -i "bg_${i}.jpg")
done
INPUTS+=(-stream_loop -1 -i bgm.mp3)
RAIN_INPUT_IDX=$N  # BGMの次のインデックス
if [ "$USE_RAIN" = true ]; then
  RAIN_INPUT_IDX=$((N + 1))
  INPUTS+=(-stream_loop -1 -i rain.mp4)
fi

# 光の帯(素材不要、ffmpegだけで生成する柔らかい光の帯。ゆっくり左右に揺れて「差し込み方が変わる」演出)
# ※処理負荷対策: 低解像度(1/6)で描いてぼかしてから最後に拡大する(フル解像度で毎フレームぼかすと非常に重いため)
LIGHT_INPUT_IDX=$((N + 1))
if [ "$USE_RAIN" = true ]; then
  LIGHT_INPUT_IDX=$((N + 2))
fi
INPUTS+=(-f lavfi -t "$TOTAL_DURATION" -i "color=c=black:s=180x320")

# 合成パーティクル(蛍/桜吹雪/落ち葉共通。素材不要。低解像度(1/6)で描いてぼかしてから最後に拡大する)
SYNTH_INPUT_IDX=$((LIGHT_INPUT_IDX + 1))
if [ "$USE_SYNTH" = true ]; then
  INPUTS+=(-f lavfi -t "$TOTAL_DURATION" -i "color=c=black:s=180x320")
fi

# パーティクルは常時・screenブレンドで重ね続ける(黒は素通り、明るい粒だけ光って見える)
PARTICLE_OPACITY=0.5

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
  FILTER="${FILTER}[${RAIN_INPUT_IDX}:v]scale=1080:1920,boxblur=1:1,format=gbrp[rainprep];"
  FILTER="${FILTER}[${PREV}]format=gbrp[prevrgb];"
  FILTER="${FILTER}[prevrgb][rainprep]blend=all_mode=screen:all_opacity=${PARTICLE_OPACITY}[rained];"
  PREV="rained"
fi

# 光の帯(常時。低解像度(180x320)で白い帯を描いてぼかし、1080x1920に拡大してから重ねる。
# 720秒(12分)周期で左右にゆっくり動かし、screenブレンドで重ねる(黒い部分は素通り、白い帯の部分だけ明るくなる)
FILTER="${FILTER}[${LIGHT_INPUT_IDX}:v]drawbox=x='57+50*sin(2*PI*t/720)':y=0:w=57:h=320:color=white:t=fill,boxblur=18:1,scale=1080:1920,format=gbrp[lightsrc];"
FILTER="${FILTER}[${PREV}]format=gbrp[prevrgb2];"
FILTER="${FILTER}[prevrgb2][lightsrc]blend=all_mode=screen:all_opacity=0.4[lighted];"
PREV="lighted"

# 合成パーティクル(蛍/桜吹雪/落ち葉。低解像度で描いてぼかしてから拡大する)
if [ "$USE_SYNTH" = true ]; then
  FILTER="${FILTER}[${SYNTH_INPUT_IDX}:v]"
  case "$SYNTH_TYPE" in
    fireflies)
      # 4つの光の玉が、それぞれ違う周期・振幅でゆっくり画面内を漂う
      FILTER="${FILTER}drawbox=x='33+50*sin(2*PI*t/9)':y='50+83*sin(2*PI*t/13+1)':w=8:h=8:color=white:t=fill,"
      FILTER="${FILTER}drawbox=x='108+53*sin(2*PI*t/11+2)':y='158+92*sin(2*PI*t/15+0.5)':w=7:h=7:color=white@0.85:t=fill,"
      FILTER="${FILTER}drawbox=x='70+43*sin(2*PI*t/8+3)':y='242+67*sin(2*PI*t/10+2.5)':w=6:h=6:color=white@0.75:t=fill,"
      FILTER="${FILTER}drawbox=x='133+37*sin(2*PI*t/12+1.5)':y='108+92*sin(2*PI*t/14+4)':w=8:h=8:color=white@0.7:t=fill,"
      FILTER="${FILTER}boxblur=3:1,scale=1080:1920,format=gbrp[synth];"
      ;;
    petals)
      # 5枚の花びらが、左右に揺れながらゆっくり下に落ち続ける(下まで着いたら上からループ)
      FILTER="${FILTER}drawbox=x='30+22*sin(2*PI*t/4)':y='mod(t*22+10,340)-20':w=7:h=5:color=#FFD9E6:t=fill,"
      FILTER="${FILTER}drawbox=x='70+18*sin(2*PI*t/3.3+1)':y='mod(t*18+90,340)-20':w=6:h=4:color=#FFC7DA@0.9:t=fill,"
      FILTER="${FILTER}drawbox=x='110+25*sin(2*PI*t/4.6+2)':y='mod(t*26+170,340)-20':w=8:h=5:color=#FFE0EC@0.85:t=fill,"
      FILTER="${FILTER}drawbox=x='145+16*sin(2*PI*t/3.8+3)':y='mod(t*20+250,340)-20':w=6:h=4:color=#FFC7DA@0.8:t=fill,"
      FILTER="${FILTER}drawbox=x='20+20*sin(2*PI*t/5+4)':y='mod(t*24+300,340)-20':w=7:h=5:color=#FFD9E6@0.75:t=fill,"
      FILTER="${FILTER}boxblur=2:1,scale=1080:1920,format=gbrp[synth];"
      ;;
    leaves)
      # 4枚の落ち葉が、大きく左右に揺れながらゆっくり下に落ち続ける(下まで着いたら上からループ)
      FILTER="${FILTER}drawbox=x='40+35*sin(2*PI*t/3)':y='mod(t*16+20,340)-20':w=9:h=6:color=#CC7A2E:t=fill,"
      FILTER="${FILTER}drawbox=x='90+30*sin(2*PI*t/3.6+1.5)':y='mod(t*14+120,340)-20':w=8:h=6:color=#B8621F@0.9:t=fill,"
      FILTER="${FILTER}drawbox=x='135+32*sin(2*PI*t/2.8+3)':y='mod(t*17+220,340)-20':w=9:h=6:color=#D98A3D@0.85:t=fill,"
      FILTER="${FILTER}drawbox=x='60+28*sin(2*PI*t/3.3+4.5)':y='mod(t*15+280,340)-20':w=7:h=5:color=#C4701F@0.8:t=fill,"
      FILTER="${FILTER}boxblur=2:1,scale=1080:1920,format=gbrp[synth];"
      ;;
  esac
  FILTER="${FILTER}[${PREV}]format=gbrp[prevrgb3];"
  FILTER="${FILTER}[prevrgb3][synth]blend=all_mode=screen:all_opacity=0.6[withsynth];"
  PREV="withsynth"
fi

# タイマー・テキストオーバーレイ(最終ノードに適用)
#
# タイマーの大きさ
#
# 一度190まで上げたが、絵を隠しすぎたので140に戻した。
# 数字を大きく見せるより、背景の情景を主役にする方針。
# 読みやすさは色を白にすることで確保する(淡い黄は縮小すると溶ける)。
#
#   110 … 控えめ。絵を最大限に見せる(現在)
#   140 … 元の大きさ
#   190 … 一覧でも確実に読めるが絵を隠す
TIMER_SIZE=110
TIMER_BORDER=7

# タイマーの縦位置
#
# 以前は上部に2行のテキスト(y=120から、64px、行間10)を置いていた。
#   1行目 120〜184 / 2行目 194〜258
# その2行目のすぐ下にあたる位置にタイマーを置く。
# 中央に置くと絵の主役部分に重なるため、上に寄せている。
#
#   120         … 元のテキスト1行目の位置
#   290         … 2行目のすぐ下(現在)
#   (h-text_h)/2 … 画面の中央
TIMER_Y=290

if [ "${TIMER_ONLY:-1}" = "1" ]; then
  echo "画面の文字: タイマーのみ(サイズ${TIMER_SIZE})"
  FILTER="${FILTER}[${PREV}]drawtext=text='%{eif\:trunc((${TOTAL_DURATION}-t)/60)\:d\:2}\\:%{eif\:mod(trunc(${TOTAL_DURATION}-t)\,60)\:d\:2}':fontfile=${FONT}:fontcolor=${TEXT_COLOR}:fontsize=${TIMER_SIZE}:x=(w-text_w)/2:y=${TIMER_Y}:font=monospace:bordercolor=${BORDER_COLOR}:borderw=${TIMER_BORDER}[vout]"
else
  # 上下テキストを出す場合、TIMER_Y だと上部テキストに重なるので中央に置く
  echo "画面の文字: タイマー＋上下テキスト"
  FILTER="${FILTER}[${PREV}]drawtext=text='%{eif\:trunc((${TOTAL_DURATION}-t)/60)\:d\:2}\\:%{eif\:mod(trunc(${TOTAL_DURATION}-t)\,60)\:d\:2}':fontfile=${FONT}:fontcolor=${TEXT_COLOR}:fontsize=${TIMER_SIZE}:x=(w-text_w)/2:y=(h-text_h)/2:font=monospace:bordercolor=${BORDER_COLOR}:borderw=${TIMER_BORDER}[t1];"
  FILTER="${FILTER}[t1]drawtext=textfile=${TOP_TEXT_FILE}:fontfile=${FONT}:fontcolor=${TEXT_COLOR}:fontsize=64:x=(w-text_w)/2:y=120:bordercolor=${BORDER_COLOR}:borderw=5:line_spacing=10[t2];"
  FILTER="${FILTER}[t2]drawtext=textfile=${BOTTOM_TEXT_FILE}:fontfile=${FONT}:fontcolor=${TEXT_COLOR}:fontsize=42:x=(w-text_w)/2:y=h-280:bordercolor=${BORDER_COLOR}:borderw=4:line_spacing=8[vout]"
fi

echo "=== レンダリング開始(天候変化${N}段階, 各源${STAGE_SRC_SEC}秒, 遷移${XFADE_SEC}秒) ==="

ffmpeg -y "${INPUTS[@]}" \
  -filter_complex "$FILTER" \
  -map "[vout]" -map "${N}:a" \
  -t "$TOTAL_DURATION" \
  -c:v libx264 -preset ultrafast -tune stillimage -r 6 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -shortest \
  "$OUTPUT"

echo "=== 完成 ==="
ffprobe -v quiet -show_entries format=duration,size -of default=noprint_wrappers=1 "$OUTPUT"
