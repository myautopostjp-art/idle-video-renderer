#!/bin/bash
# =====================================================
# YouTube長尺BGM動画レンダリングスクリプト(高品質版)
# 配置場所: リポジトリの render_youtube_long.sh
#
# 構成: 導入部(LTX動画、動きあり) + ループ部分(各段階が短い動画クリップのループ、常に動いている)
# 引数: $1=導入動画URL $2=BGM URL $3=総尺(秒) $4=導入部秒数 $5=出力ファイル名 $6以降=ループ用の段階動画クリップURL(6本)
# 環境変数: AMBIENT_SOUND_URL=効果音URL(省略可。省略時はBGMのみ)
#           PARTICLE_KEY=情景の種類(省略可。音のEQを切り替えるのに使う)
#           TRANSITIONS=段階間の変化速度(例: "slow,slow,fast")
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
echo "particleKey: ${PARTICLE_KEY:-未指定}"

# ---- ①素材のダウンロード ----
#
# 【修正】curlに -f を付けた。
# 以前は -L -s だけだったため、URLが切れていても「404のHTML」を
# intro_video.mp4 という名前で保存して正常終了してしまい、
# 数ステップ先のffmpegが意味不明なエラーで落ちて原因が追えなかった。
# -f を付ければ、その場でダウンロード失敗として止まる。
download_or_die_() {
  local url="$1" out="$2" label="$3"
  echo "${label}をダウンロード中..."
  if ! curl -fL -sS --retry 2 --retry-delay 3 -o "$out" "$url"; then
    echo "エラー: ${label}のダウンロードに失敗しました"
    echo "  URL: $url"
    echo "  Driveの共有設定が「リンクを知っている全員」になっているか確認してください"
    exit 1
  fi
}

download_or_die_ "$INTRO_VIDEO_URL" intro_video.mp4 "導入動画"
download_or_die_ "$BGM_URL" bgm.mp3 "BGM"

# 効果音のダウンロード(URLが指定されている場合のみ)
HAS_AMBIENT=false
if [ -n "$AMBIENT_SOUND_URL" ] && [ "$AMBIENT_SOUND_URL" != "none" ]; then
  download_or_die_ "$AMBIENT_SOUND_URL" ambient.mp3 "効果音"
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
  download_or_die_ "${STAGE_CLIP_URLS[$i]}" "stage_clip_raw_$i.mp4" "クリップ$((i+1))"
done

# ---- ①-2 クリップの再生速度を落とす ----
#
# 【なぜ必要か】
# LTXにプロンプトで「雲はほとんど動かない」と指示しても守られず、
# ループ部分の雲だけが早回しのように流れてしまう。
# 導入部の雲はゆっくり動くため、切り替わる瞬間に速度差が目立つ。
#
# プロンプトで抑えきれない以上、生成後に再生速度を落とすのが確実。
# 湯気や水面もあわせてゆっくりになるが、放置動画では
# むしろ落ち着いて見えるので都合がよい。
#
# 副産物として、6秒のクリップが15秒に伸びるためループ周期も長くなり、
# 「同じ映像の繰り返し」に気づかれにくくなる。
#
# 【vidstabによる安定化は廃止した】
# 隙間埋めのための拡大(zoom=8)がループクリップだけに掛かるため、
# 導入部から切り替わる瞬間に画が一回り大きくなる問題を起こしていた。
# ドリフト対策はシームレスループ加工(末尾と先頭のクロスフェード)に一本化する。
# 【調整の目安】
#   1.0  … 等速(LTXが生成したまま。雲が早回しに見える)
#   0.6  … 6秒→10秒。雲は落ち着くが、導入部のほぼ静止した雲とはまだ差がある
#   0.4  … 6秒→15秒。雲の動きが1/3以下になり、導入部との差がほぼ分からなくなる
#          湯気や水面もゆっくりになるが、放置動画ではむしろ落ち着いて見える
LOOP_SPEED=0.4

# 【診断用】導入部とループクリップの解像度を記録しておく
# 両者の縦横比が違うと、画面に収める際の拡大率が変わり、
# 切り替わる瞬間に画が広がったように見えてしまう
echo "--- 素材の解像度 ---"
echo -n "  導入部: "
ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 intro_video.mp4 || true
for ((i=0; i<CLIP_COUNT; i++)); do
  echo -n "  ループクリップ$((i+1)): "
  ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "stage_clip_raw_$i.mp4" || true
done

echo "ループクリップの再生速度を${LOOP_SPEED}倍に落とします(雲の流れを導入部に合わせるため)..."
for ((i=0; i<CLIP_COUNT; i++)); do
  if ffmpeg -y -i "stage_clip_raw_$i.mp4" \
       -vf "setpts=PTS/${LOOP_SPEED},fps=30" -an \
       -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p "stage_clip_$i.mp4" 2>"err_speed_$i.log"; then
    RAW_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "stage_clip_raw_$i.mp4")
    NEW_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "stage_clip_$i.mp4")
    echo "  クリップ$((i+1)): ${RAW_DUR}秒 → ${NEW_DUR}秒"
  else
    cp "stage_clip_raw_$i.mp4" "stage_clip_$i.mp4"
    echo "  クリップ$((i+1)): 速度変更に失敗したため、そのまま使います"
    tail -3 "err_speed_$i.log" || true
  fi
done

# ---- ①-2b ループクリップのカメラドリフトを止める ----
#
# 【なぜ必要か】
# プロンプトで "The camera is locked off on a fixed mount... no pan, no tilt, no drift"
# と強く書いてもLTXは守らず、ループクリップの中でカメラがゆっくり一方向に流れる。
# ループは12秒で先頭に戻るため、視聴者には
# 「12秒かけてスクロールしては元に戻る」という不自然な繰り返しに見えてしまう。
#
# プロンプトで3回試して直らなかったので、後処理で確実に潰す方針に切り替える。
#
# 【以前vidstabを廃止した理由と、その解決】
# 以前は隙間を埋める拡大(zoom)がループクリップにだけ掛かっていたため、
# 導入部から切り替わる瞬間に画が一回り大きくなる問題が起きて廃止した。
# 今回は「導入部にもまったく同じ倍率の拡大をかける」ことで解決する。
# 下の STABILIZE_ZOOM は⑤の導入部処理でも同じ値が使われる。
#
# smoothing=0 は「カメラは静止しているはず」という前提で補正するモード。
# 移動平均で滑らかにするのではなく、ドリフトそのものを打ち消す。
STABILIZE_ZOOM=8   # 補正で生じる縁の隙間を埋めるための拡大率(%)

# ffmpegがvidstabを含まないビルドの場合もあるため、使えるか先に確認する
# (使えなければ安定化を飛ばす。動画自体は作れる)
HAS_VIDSTAB=false
if ffmpeg -hide_banner -filters 2>/dev/null | grep -q vidstabtransform; then
  HAS_VIDSTAB=true
else
  echo "※このffmpegはvidstabを含まないため、カメラの安定化を飛ばします"
fi

if [ "$HAS_VIDSTAB" = true ]; then
  echo "ループクリップのカメラドリフトを補正します(拡大${STABILIZE_ZOOM}%)..."
  for ((i=0; i<CLIP_COUNT; i++)); do
    if ffmpeg -y -i "stage_clip_$i.mp4" \
         -vf "vidstabdetect=shakiness=4:accuracy=15:result=transforms_$i.trf" \
         -f null - 2>"err_vsdetect_$i.log" \
       && ffmpeg -y -i "stage_clip_$i.mp4" \
         -vf "vidstabtransform=input=transforms_$i.trf:smoothing=0:optzoom=0:zoom=${STABILIZE_ZOOM}:interpol=bicubic" \
         -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -r 30 -an "stage_stab_$i.mp4" 2>"err_vstrans_$i.log"; then
      mv "stage_stab_$i.mp4" "stage_clip_$i.mp4"
      echo "  クリップ$((i+1)): ドリフトを補正しました"
    else
      echo "  クリップ$((i+1)): 補正に失敗したため、そのまま使います"
      tail -3 "err_vsdetect_$i.log" "err_vstrans_$i.log" 2>/dev/null || true
      # 補正できなかった場合、このクリップだけ拡大されない状態になる。
      # 導入部との大きさを揃えるため、拡大だけは同じ倍率でかけておく。
      if ffmpeg -y -i "stage_clip_$i.mp4" \
           -vf "crop=iw/(1+${STABILIZE_ZOOM}/100):ih/(1+${STABILIZE_ZOOM}/100),scale=1920:1080" \
           -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -r 30 -an "stage_zoom_$i.mp4" 2>/dev/null; then
        mv "stage_zoom_$i.mp4" "stage_clip_$i.mp4"
      fi
    fi
  done
fi

# ---- ①-3 クリップをシームレスループに加工する ----
#
# 6秒のクリップをそのまま繰り返すと、最後のフレームから最初のフレームへ
# 一瞬で切り替わるため、位置や湯気の形の差が「カクッ」という違和感になる。
#
# そこで末尾と先頭をクロスフェードで溶かし合わせ、
# 「終わりの画=始まりの画」となる完全ループを作る。
#
#   [本体][末尾が先頭へ溶けていく]
#    → 継ぎ目が原理的に存在しなくなる
#
# 湯気・水面・星の瞬きは形の定まらない被写体なので、
# 数秒のディゾルブは自然な動きにしか見えない。
# カメラのドリフトが残っていても、跳ぶのではなく柔らかく溶けるため目立たない。
#
# ループの継ぎ目を溶かす秒数
# 長いほど繋ぎ目が分かりにくくなるが、その分ループ周期が短くなる
XFADE_LOOP=3

# 導入部とループの境目を溶かす秒数
#
# ループの継ぎ目(XFADE_LOOP)とは別に設定する。
# 導入部の終盤はカメラが停止しているため、長く溶かすと二重像が
# 動かないまま居座り、「残像」として見えてしまう。
# 1秒程度なら、残像と認識される前に切り替わりが終わる。
XFADE_INTRO=1

# 導入部の冒頭から切り落とす秒数
#
# LTXは生成の最初の数秒で急旋回し、強いモーションブラーを出すことがある。
# ここが視聴者に画面酔いを起こさせる原因になるため、物理的に捨てる。
#   0   … 切らない(以前の挙動)
#   3   … 冒頭3秒を捨てる(急旋回はほぼこの範囲に収まる)
INTRO_HEAD_CUT=3

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
      -map "[out]" -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -r 30 -an "stage_loop_$i.mp4" 2>"err_loop_$i.log"; then
    LOOP_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "stage_loop_$i.mp4")
    echo "  クリップ$((i+1)): シームレスループ化しました(${CLIP_DUR}秒 → ${LOOP_DUR}秒)"

    # 【重要】加工後のクリップは「元の${XFADE_LOOP}秒地点」から始まる。
    # 導入部の最終フレームは元の0秒地点なので、そのまま繋ぐと
    # 切り替わった瞬間に${XFADE_LOOP}秒分の動きが飛んでしまう。
    # そこで元の0〜${XFADE_LOOP}秒を別に取っておき、ループの一番最初にだけ挟む。
    #   [導入部 …元の0秒][元の0〜3秒][加工済みループ(3秒地点から)]…
    # こうすれば全ての繋ぎ目が連続する。
    ffmpeg -y -i "stage_clip_$i.mp4" -t "$XFADE_LOOP" \
      -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -r 30 -an "loop_head_$i.mp4" 2>"err_head_$i.log"

    mv "stage_loop_$i.mp4" "stage_clip_$i.mp4"
  else
    echo "  クリップ$((i+1)): 加工に失敗したため、そのまま使います"
    tail -3 "err_loop_$i.log" || true
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
echo "境目ごとの変化速度: ${XFADE_DURATIONS[*]:-なし(段階が1つのみ)}"

# 【修正】段階が2つ以上あるときだけ、キーフレーム間隔を0.5秒に詰める。
#
# 後の工程で本体部分を `-ss 秒数 -c copy` で切り出すが、
# 再エンコードしない切り出しは直前のキーフレームまで戻ってしまう。
# 既定のキーフレーム間隔(250フレーム≒8秒)のままだと、
# 境目の位置が最大8秒ずれて繋ぎ目が破綻する。
# 0.5秒間隔なら、境目に使う1.5秒・12秒がどちらもキーフレーム上に乗る。
#
# 間隔を詰めるとファイルが1〜2割大きくなるため、
# 切り出しが発生しない1段階のときは既定のままにしておく(Releaseの2GB制限対策)。
if [ "$CLIP_COUNT" -gt 1 ]; then
  GOP_OPTS="-g 15 -keyint_min 15 -sc_threshold 0"
  echo "キーフレーム間隔を0.5秒に設定します(境目の切り出しを正確にするため)"
else
  GOP_OPTS=""
fi

# 導入部にかける拡大の指定を組み立てる
#
# 安定化でループ側が STABILIZE_ZOOM % 拡大されるため、導入部にも同じ倍率をかけて
# 切り替わる瞬間に画の大きさが変わらないようにする。
# 安定化を行わなかった場合は拡大なし(空文字)。
if [ "$HAS_VIDSTAB" = true ]; then
  INTRO_ZOOM_VF="crop=iw/(1+${STABILIZE_ZOOM}/100):ih/(1+${STABILIZE_ZOOM}/100),scale=1920:1080,"
  echo "導入部にもループと同じ${STABILIZE_ZOOM}%の拡大をかけます(切り替わりで画の大きさを揃えるため)"
else
  INTRO_ZOOM_VF=""
fi

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
#
# 【修正】このブロックのffmpegから 2>/dev/null を外した。
# set -e が効いているため、失敗すると即座にスクリプトが終了するが、
# 標準エラーを捨てていたせいで何のメッセージも残らず、
# 40分の処理の途中で無言で死ぬ状態になっていた。
echo "各段階の動画を用意します..."
for ((i=0; i<CLIP_COUNT; i++)); do
  BEFORE=0
  AFTER=0
  [ "$i" -gt 0 ] && BEFORE="${XFADE_DURATIONS[$((i-1))]}"
  [ "$i" -lt "$((CLIP_COUNT-1))" ] && AFTER="${XFADE_DURATIONS[$i]}"

  # この段階が必要とする総尺(本体 + 前後の境目に供出する分)
  #
  # 最初の段階だけは、導入部との繋ぎ目を連続させるため
  # 「元の0〜3秒」を先頭に挟んでからループさせる
  if [ "$i" -eq 0 ] && [ -f "loop_head_$i.mp4" ]; then
    # 【導入部との境目を溶かす】
    #
    # 導入部の映像は等速だが、ループ部分は再生速度を落としてある。
    # 位置や画角が完全に一致していても、湯気や雲の動く速さが変わるため
    # 切り替わった瞬間に「何かが変わった」と感じられてしまう。
    #
    # 導入部の末尾とループの先頭を重ねて溶かすと、
    # 移り変わっている最中はテンポの比較ができなくなり、違和感が消える。
    BODY_LEN=$(awk "BEGIN{print $STAGE_DURATION - $XFADE_LOOP}")
    ffmpeg -y -stream_loop -1 -i "stage_clip_$i.mp4" -t "$BODY_LEN" \
      -vf "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080" \
      -c:v libx264 -preset veryfast -crf 23 $GOP_OPTS -pix_fmt yuv420p -r 30 -an "stage_body_$i.mp4"
    ffmpeg -y -i "loop_head_$i.mp4" \
      -vf "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080" \
      -c:v libx264 -preset veryfast -crf 23 $GOP_OPTS -pix_fmt yuv420p -r 30 -an "stage_headpart_$i.mp4"

    # 導入部の末尾を切り出して、ループの先頭と溶かし合わせる
    #
    # 【なぜループの継ぎ目とは別の秒数にするか】
    # ループの継ぎ目(XFADE_LOOP)は長いほど滑らかになるが、
    # 導入部との境目は長いほど「残像」が目立つ。
    # 導入部の終盤はカメラが停止しているため、二重像が動かずに居座ってしまう。
    # そのため境目だけを短くして、残像として認識される前に切り替え終える。
    INTRO_REAL=$(ffprobe -v error -show_entries format=duration -of csv=p=0 intro_video.mp4)
    TAIL_FROM=$(awk "BEGIN{v=$INTRO_REAL - $XFADE_INTRO; if(v<0) v=0; print v}")
    # 冒頭カットぶんを差し引いた、実際に使う導入部の長さ
    INTRO_USED=$(awk "BEGIN{v=$INTRO_REAL - $INTRO_HEAD_CUT; if(v<1) v=$INTRO_REAL; print v}")
    HEAD_REST=$(awk "BEGIN{print $XFADE_LOOP - $XFADE_INTRO}")

    # ループ先頭部分を「境目で溶かす分」と「そのまま流す分」に分ける
    ffmpeg -y -i "stage_headpart_$i.mp4" -t "$XFADE_INTRO" \
      -c:v libx264 -preset veryfast -crf 23 $GOP_OPTS -pix_fmt yuv420p -r 30 -an "head_blend_$i.mp4"
    HAS_HEAD_REST=false
    if awk "BEGIN{exit !($HEAD_REST > 0.05)}"; then
      ffmpeg -y -ss "$XFADE_INTRO" -i "stage_headpart_$i.mp4" \
        -c:v libx264 -preset veryfast -crf 23 $GOP_OPTS -pix_fmt yuv420p -r 30 -an "head_rest_$i.mp4" \
        && HAS_HEAD_REST=true
    fi

    # 【重要】導入部にもループと同じ拡大をかける。
    # 安定化の拡大がループ側にだけ掛かると、切り替わる瞬間に画が一回り大きくなる。
    if ffmpeg -y -ss "$TAIL_FROM" -i intro_video.mp4 -t "$XFADE_INTRO" -an \
         -vf "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,${INTRO_ZOOM_VF}fps=30" \
         -c:v libx264 -preset veryfast -crf 23 $GOP_OPTS -pix_fmt yuv420p "intro_tail.mp4" 2>"err_introtail.log" \
       && ffmpeg -y -i "intro_tail.mp4" -i "head_blend_$i.mp4" \
         -filter_complex "[0:v][1:v]xfade=transition=fade:duration=${XFADE_INTRO}:offset=0[v]" \
         -map "[v]" -c:v libx264 -preset veryfast -crf 23 $GOP_OPTS -pix_fmt yuv420p -r 30 -an "boundary.mp4" 2>"err_boundary.log"; then
      if [ "$HAS_HEAD_REST" = true ]; then
        printf "file 'boundary.mp4'\nfile 'head_rest_%d.mp4'\nfile 'stage_body_%d.mp4'\n" "$i" "$i" > "headjoin_$i.txt"
      else
        printf "file 'boundary.mp4'\nfile 'stage_body_%d.mp4'\n" "$i" > "headjoin_$i.txt"
      fi
      INTRO_TRIM="$TAIL_FROM"
      echo "  段階1: 導入部との境目を${XFADE_INTRO}秒かけて溶かします(ループの継ぎ目は${XFADE_LOOP}秒)"
    else
      printf "file 'stage_headpart_%d.mp4'\nfile 'stage_body_%d.mp4'\n" "$i" "$i" > "headjoin_$i.txt"
      echo "  段階1: 境目の加工に失敗したため、そのまま繋ぎます"
      tail -3 err_introtail.log err_boundary.log 2>/dev/null || true
    fi
    ffmpeg -y -f concat -safe 0 -i "headjoin_$i.txt" -c copy "stage_$i.mp4"
  else
    ffmpeg -y -stream_loop -1 -i "stage_clip_$i.mp4" -t "$STAGE_DURATION" \
      -vf "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080" \
      -c:v libx264 -preset veryfast -crf 23 $GOP_OPTS -pix_fmt yuv420p -r 30 -an "stage_$i.mp4"
  fi

  # 境目に使う部分を切り出す
  #   前の境目用: この段階の先頭BEFORE秒
  #   後の境目用: この段階の末尾AFTER秒
  if [ "$(awk "BEGIN{print ($AFTER > 0)}")" = "1" ]; then
    TAIL_START=$(awk "BEGIN{print $STAGE_DURATION - $AFTER}")
    ffmpeg -y -ss "$TAIL_START" -i "stage_$i.mp4" -t "$AFTER" \
      -c:v libx264 -preset veryfast -crf 23 $GOP_OPTS -pix_fmt yuv420p -r 30 -an "tail_$i.mp4"
  fi
  if [ "$(awk "BEGIN{print ($BEFORE > 0)}")" = "1" ]; then
    ffmpeg -y -i "stage_$i.mp4" -t "$BEFORE" \
      -c:v libx264 -preset veryfast -crf 23 $GOP_OPTS -pix_fmt yuv420p -r 30 -an "head_$i.mp4"
  fi

  # 本体部分(境目に供出した分を除いた中間部分)を切り出す
  # 再エンコードしないので速いが、切り出し位置はキーフレームに丸められる。
  # そのため上で GOP_OPTS によりキーフレーム間隔を0.5秒に詰めてある。
  BODY_DURATION=$(awk "BEGIN{print $STAGE_DURATION - $BEFORE - $AFTER}")
  ffmpeg -y -ss "$BEFORE" -i "stage_$i.mp4" -t "$BODY_DURATION" \
    -c copy "body_$i.mp4"
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
      -map "[v]" -c:v libx264 -preset veryfast -crf 23 $GOP_OPTS -pix_fmt yuv420p -r 30 -an "xfade_$i.mp4"
    echo "file 'xfade_$i.mp4'" >> concat_loop.txt
  fi
done

# 本体とクロスフェードを順に連結する(再エンコードなし = 高速)
ffmpeg -y -f concat -safe 0 -i concat_loop.txt -c copy loop_video.mp4

echo "ループ部分の結合が完了しました"

# ---- ⑤導入部とループ部分をつなげる(映像のみ、音声は後で合成) ----
#      【重要】導入部とループ部分で解像度やフレームレートが違うと、
#      連結した動画の途中で画角が変わってしまう。
#      以前は導入部を -c:v copy でそのまま使っていたためこの問題が起きていた。
#      ここでループ部分と同じ 1920x1080 / 30fps に揃えてから連結する。
echo "導入部をループ部分と同じ規格に揃えます..."
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate \
  -of default=nw=1 intro_video.mp4 || true

# ---- 冒頭の急旋回を切り落とす ----
#
# LTXが生成の最初の数秒で急旋回し、強いモーションブラーを出すため、
# その区間を物理的に捨てる(プロンプトでは2回連続で抑えられなかった)。
# -ss は -i より前に置くと高速シークになるが、再エンコードするので精度は問題ない。
INTRO_SS=""
if awk "BEGIN{exit !($INTRO_HEAD_CUT > 0.05)}"; then
  INTRO_SS="-ss $INTRO_HEAD_CUT"
  echo "  冒頭${INTRO_HEAD_CUT}秒を切り落とします(急旋回とモーションブラー対策)"
fi

# 境目を溶かした場合、その分は既にループ側の先頭に含まれているため
# 導入部からは末尾を取り除いておく(重複を避ける)
#
# 【注意】-ss で冒頭を飛ばした場合、-t は「そこからの長さ」になる。
# そのため末尾を取り除く長さも、冒頭カットぶんを差し引いて計算する。
INTRO_CUT=""
if [ -n "${INTRO_TRIM:-}" ]; then
  INTRO_KEEP=$(awk "BEGIN{v=$INTRO_TRIM - $INTRO_HEAD_CUT; if(v<1) v=$INTRO_TRIM; print v}")
  INTRO_CUT="-t $INTRO_KEEP"
  echo "  境目に使った末尾${XFADE_INTRO}秒を導入部から取り除きます(実際に使う導入部: ${INTRO_KEEP}秒)"
fi
ffmpeg -y $INTRO_SS -i intro_video.mp4 $INTRO_CUT -an \
  -vf "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,${INTRO_ZOOM_VF}fps=30" \
  -c:v libx264 -preset veryfast -crf 23 $GOP_OPTS -pix_fmt yuv420p intro_video_noaudio.mp4

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

# BGMのフェードインを始める時刻
#
# ※効果音がある場合は、下の「空間変化」方式が優先される。
#   この値は空間変化に失敗したときのフォールバックと、BGMのみの場合に使う。
# 冒頭カット後、実際に画面に出る導入部の長さ
# 音の切り替わり(室内→屋外)はこの秒数に合わせる
INTRO_EFFECTIVE=$(awk "BEGIN{v=$INTRO_DURATION - $INTRO_HEAD_CUT; if(v<3) v=$INTRO_DURATION; print v}")
echo "音のタイミング基準: ${INTRO_EFFECTIVE}秒(指定${INTRO_DURATION}秒 − 冒頭カット${INTRO_HEAD_CUT}秒)"

# ---- 音が「開ける」瞬間 ----
#
# 戸を抜けて外に出るのは導入部の終盤なので、その手前まで室内の音を保ち、
# 最後の OPEN_DURATION 秒かけて屋外の音へ切り替える。
#
# 【調整の経緯】
#   0秒から導入部いっぱい … 変化がゆるやかすぎて「開けた瞬間」を感じられない
#   最後の4秒に集中       … 今度は切り替わりが急すぎた
#   最後の8秒(現在)       … その中間。歩きながら少しずつ開けていく感じになる
#
# もっとゆっくりにしたいなら数字を大きく、はっきりさせたいなら小さくする。
OPEN_DURATION=8
OPEN_START=$(awk "BEGIN{v=$INTRO_EFFECTIVE - $OPEN_DURATION; if(v<1) v=1; print v}")
echo "音が開ける瞬間: ${OPEN_START}秒から${OPEN_DURATION}秒かけて室内→屋外へ(それまでは室内の音のまま)"

BGM_FADE_DURATION=5
BGM_FADE_START=$(awk "BEGIN{v=$INTRO_EFFECTIVE-7; if(v<0) v=0; print v}")
# ※空間変化が使えない環境では、このフェードインだけで室内→屋外を表現する

# 効果音あり・なしで処理を分岐する
if [ "$HAS_AMBIENT" = true ]; then
  echo "効果音+BGMの合成を行います(帯域を棲み分けてミックス)..."

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
  #
  # ※PARTICLE_KEY は render.yml から環境変数として渡される。
  #   未指定のときは雨・波向けの設定(*)になる。

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

  # BGM: 室内では編成が薄く、外に出ると開けるように変化させる
  #
  # 【設計】
  # 導入部で別の曲を流すと、切り替わる瞬間に「曲が変わった」と分かってしまう。
  # そこで同じ曲のまま、室内にいるあいだは音を削っておく。
  #
  #   室内: 高域を落とす → 琴の粒立ちや倍音が消え、パッドと低域だけが残る
  #         響きを増やす → 隣の部屋から漏れ聴こえるような距離感になる
  #         音量を絞る
  #   屋外: 削っていた帯域が戻り、音量も上がる
  #
  # 曲そのものは変わっていないのに、戸を開けた瞬間に楽器が増えたように聴こえる。
  # 「同じ音楽が空間ごと広がる」体験になり、繋ぎ目が生まれない。
  #
  # ※効果音の距離変化と同じ2本方式。lowpassは時間で変化させられないため、
  #   こもった版と開けた版を別々に作って入れ替える。
  BGM_INDOOR_LOWPASS=1800    # 室内で残す帯域の上限(下げるほど編成が薄く聴こえる)
  BGM_INDOOR_VOLUME=0.32     # 室内でのBGM音量(屋外は0.8)
  BGM_OPENING=$(awk "BEGIN{v=$INTRO_EFFECTIVE; if(v<3) v=3; print v}")
  echo "BGMの空間変化: 室内(${BGM_INDOOR_LOWPASS}Hz以下・音量${BGM_INDOOR_VOLUME}) → ${OPEN_START}秒から${OPEN_DURATION}秒で屋外へ開く"

  # 室内で聴こえている状態(こもって、響いて、控えめ)
  ffmpeg -y -stream_loop -1 -i bgm.mp3 -t "$TOTAL_DURATION" \
    -af "${BGM_EQ},lowpass=f=${BGM_INDOOR_LOWPASS},aecho=0.8:0.9:180:0.4,volume=${BGM_INDOOR_VOLUME}" \
    -c:a pcm_s16le bgm_indoor.wav

  # 屋外に出た状態(開けて、通常音量)
  ffmpeg -y -stream_loop -1 -i bgm.mp3 -t "$TOTAL_DURATION" \
    -af "${BGM_EQ},volume=0.8" \
    -c:a pcm_s16le bgm_outdoor.wav

  # 導入部をかけて室内の響きから屋外の響きへ入れ替える
  if ffmpeg -y -i bgm_indoor.wav -i bgm_outdoor.wav -filter_complex \
      "[0:a]afade=t=out:st=${OPEN_START}:d=${OPEN_DURATION}:curve=tri[ind];\
[1:a]afade=t=in:st=${OPEN_START}:d=${OPEN_DURATION}:curve=tri[outd];\
[ind][outd]amix=inputs=2:duration=longest:normalize=0[out]" \
      -map "[out]" -c:a pcm_s16le bgm_full.wav 2>err_bgmspace.log; then
    echo "BGMに空間変化を適用しました(室内では編成が薄く聴こえます)"
    rm -f bgm_indoor.wav bgm_outdoor.wav
  else
    echo "空間変化の適用に失敗したため、従来のフェードインで処理します"
    tail -3 err_bgmspace.log || true
    ffmpeg -y -stream_loop -1 -i bgm.mp3 -t "$TOTAL_DURATION" \
      -af "${BGM_EQ},afade=t=in:st=${BGM_FADE_START}:d=${BGM_FADE_DURATION},volume=0.8" \
      -c:a pcm_s16le bgm_full.wav
  fi

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
  DIST_FAR_VOL=$(awk "BEGIN{printf \"%.3f\", $AMBIENT_LOOP_VOLUME * 0.28}")
  echo "効果音の距離変化: 遠(${DIST_FAR_VOL}/こもり) → ${OPEN_START}秒から${OPEN_DURATION}秒で → 近(${AMBIENT_LOOP_VOLUME}/開け)"

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
      "[0:a]afade=t=out:st=${OPEN_START}:d=${OPEN_DURATION}:curve=tri[far];\
[1:a]afade=t=in:st=${OPEN_START}:d=${OPEN_DURATION}:curve=tri[near];\
[far][near]amix=inputs=2:duration=longest:normalize=0[out]" \
      -map "[out]" -c:a pcm_s16le ambient_full.wav 2>err_ambdist.log; then
    echo "効果音に距離変化を適用しました"
    rm -f ambient_far.wav ambient_near.wav
  else
    # 失敗した場合は一定音量で処理する
    echo "距離変化の適用に失敗したため、一定音量で処理します"
    tail -3 err_ambdist.log || true
    ffmpeg -y -stream_loop -1 -i ambient.mp3 -t "$TOTAL_DURATION" \
      -af "${AMBIENT_EQ_BASE},lowpass=f=${AMBIENT_LOWPASS},volume=${AMBIENT_LOOP_VOLUME}" \
      -c:a pcm_s16le ambient_full.wav
  fi

  # BGM + 効果音をミックス
  #   ミックス後に軽いコンプレッションをかけ、2つの音を同じダイナミクスにまとめる
  #   (別々に鳴っている感じを減らし、ひとつの音像として聴かせる)
  ffmpeg -y -i bgm_full.wav -i ambient_full.wav \
    -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0[mixed];[mixed]acompressor=threshold=0.15:ratio=3:attack=200:release=1000[aout]" \
    -map "[aout]" -c:a aac -b:a 192k full_audio.aac

else
  echo "BGMのみで音声合成を行います..."
  echo "BGMフェードイン: ${BGM_FADE_START}秒から${BGM_FADE_DURATION}秒かけて立ち上げ(導入部は${INTRO_EFFECTIVE}秒)"

  # BGM: ループして、窓へ向かうあたりからフェードイン
  ffmpeg -y -stream_loop -1 -i bgm.mp3 -t "$TOTAL_DURATION" \
    -af "afade=t=in:st=${BGM_FADE_START}:d=${BGM_FADE_DURATION}" \
    -c:a aac -b:a 192k full_audio.aac
fi

# ---- ⑦映像と音声を結合 ----
# 【修正】音声は既にAACなので再エンコードせずコピーする(二重エンコードによる劣化を避ける)
ffmpeg -y -i full_video_noaudio.mp4 -i full_audio.aac \
  -map 0:v -map 1:a -c:v copy -c:a copy -shortest "$OUTPUT_FILE"

echo "=== レンダリング完了: $OUTPUT_FILE ==="
ls -la "$OUTPUT_FILE"
