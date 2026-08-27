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
# ループクリップの再生速度
#
# 【トレードオフ】
# 遅くするほどループ周期が長くなり、繰り返し感が減る。
# しかし遅すぎると、石樋から落ちる水のような速い動きが
# 止まって見えてしまう(0.4で実際にそうなった)。
#
#   0.4 … 周期12.3秒。水はやや遅いが、繰り返しが目立たない(現在)
#   0.6 … 周期7.2秒。水は自然に流れるが、7秒ごとの繰り返しが強く出た
#
# 0.6を試したところ、水の見え方は改善したものの、
# ループの周期が短くなったぶん「カクッと戻る」感じが強くなった。
# 1時間流す動画では繰り返しの目立ちにくさを優先するため0.4に戻す。
#
# ※この値を変えたら render.yml の LOOP_PERIOD も直すこと
#   (Geminiの動画チェックが1周期分を切り出すのに使っている)
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
# 【拡大率の調整】
# 8%では LOOP_SPEED=0.6 のときにドリフトを吸収しきれず、
# ループの継ぎ目で「カクッと戻る」動きが残った。
# 速度を上げた分だけ単位時間あたりの移動量も増えるため、拡大率も上げる。
# 【この値はもう使われていません】
#
# ドリフトは「測って線形に打ち消す」方式に変えたため、
# vidstabによる補正と、それに伴う大きな拡大は不要になった。
# 必要な拡大率はクリップごとに実測値から自動で決まる(検証では2.6%)。
#
# 以下は当時の記録として残す。
#
# 【かつて18%にしていた理由】
# LTXはカメラを固定しろと指示しても必ずドリフトする。これは業界共通の問題で、
# プロンプトでは止められない。試した対策と結果は次のとおり:
#
#   end_image_url を開始画像と同じにする … カメラは止まるが湯も湯気も止まる(2回とも再発)
#   XFADE_LOOP を6秒に延ばす            … カクッは減るが建物の輪郭が二重に見える
#   STABILIZE_ZOOM=10                    … ドリフトを吸収しきれず残った
#
# 結局vidstabで消すのが最も確実で、10%で足りなかったぶん18%まで上げる。
# 上下左右それぞれ約9%が枠外に出るため画角は狭くなるが、
# 二重像やカクッとした飛びよりは許容できる。
#
# ※第二弾以降は、画像生成の段階で構図を広めに作れば
#   拡大で削られても余裕が残るようにできる。
STABILIZE_ZOOM=18   # 補正で生じる縁の隙間を埋めるための拡大率(%)

# ffmpegがvidstabを含まないビルドの場合もあるため、使えるか先に確認する
# (使えなければ安定化を飛ばす。動画自体は作れる)
# vidstabはもう使っていない(ドリフトは実測して線形に打ち消す方式に変更)。
# 変数だけ残してあるのは、他の箇所から参照されていないことを確認済みのため。
HAS_VIDSTAB=false
if [ -n "${LAYER_REGIONS:-}" ] && [ -n "${BASE_IMAGE_URL:-}" ]; then
  # レイヤー合成モードでは建物や空は静止画から取るためドリフトは存在しない。
  # クリップは湯の領域にしか使われず、そこだけ拡大すると静止画と位置が
  # 合わなくなるので、安定化は行わない。
  echo "レイヤー合成モードのため、カメラの安定化は行いません"
elif awk "BEGIN{exit !($STABILIZE_ZOOM < 0.5)}"; then
  echo "カメラの安定化は行いません(ドリフトはループの継ぎ目を長く溶かして吸収します)"
elif ffmpeg -hide_banner -filters 2>/dev/null | grep -q vidstabtransform; then
  HAS_VIDSTAB=true
else
  echo "※このffmpegはvidstabを含まないため、カメラの安定化を飛ばします"
fi

# ============================================================
# ループクリップのドリフトを「測って打ち消す」
#
# 【なぜvidstabをやめたか】
# vidstabは手ぶれ補正の道具で、毎フレーム細かく揺れを追いかける。
# そのため補正量の最大値に合わせて大きく拡大する必要があり、
# 18%拡大しても打ち消しきれず、画角だけが削られていた。
#
# LTXのドリフトは「一定方向へじわじわ流れる」動きなので、
# 先頭と末尾を比べて移動量を測り、その分だけ線形に逆へ動かせば消える。
# 検証では 拡大2.6% で完全にゼロ(x=0,y=0)になった。
#
# 【測り方】
# 末尾フレームを少しずつずらして先頭フレームと重ね、
# 最も一致する位置を探す。そのずれ量がドリフト量になる。
# ============================================================
measure_drift_() {
  # $1 = 動画ファイル / 出力: "DX DY" (末尾が先頭に対してずれている量)
  local V="$1"
  local D W H
  D=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$V")
  W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$V")
  H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$V")
  local LAST
  LAST=$(awk -v d="$D" 'BEGIN{v=d-0.1; if(v<0)v=0; printf "%.2f", v}')

  # 【二段階で測る理由】
  # 縮小して測ると処理は軽いが、縮小率の分だけ粗くなる。
  # 1/4で測ると4px刻みになり、数pxのずれが「0」と判定されてしまう。
  # 実際には2〜3pxのずれでも継ぎ目のカクッとして見えるため、
  # まず縮小版で大まかな位置を掴み、次に原寸でその周辺を1px刻みで詰める。
  ffmpeg -v error -ss 0 -i "$V" -frames:v 1 -vf "scale=iw/4:ih/4" -y drift_a.png 2>/dev/null || { echo "0 0"; return; }
  ffmpeg -v error -ss "$LAST" -i "$V" -frames:v 1 -vf "scale=iw/4:ih/4" -y drift_b.png 2>/dev/null || { echo "0 0"; return; }
  ffmpeg -v error -ss 0 -i "$V" -frames:v 1 -y drift_a_full.png 2>/dev/null || { echo "0 0"; return; }
  ffmpeg -v error -ss "$LAST" -i "$V" -frames:v 1 -y drift_b_full.png 2>/dev/null || { echo "0 0"; return; }

  python3 - <<'DRIFTPY'
from PIL import Image
try:
    a = Image.open('drift_a.png').convert('L')
    b = Image.open('drift_b.png').convert('L')
except Exception:
    print("0 0"); raise SystemExit
w, h = a.size
ap, bp = a.load(), b.load()
mx, my = int(w*0.25), int(h*0.25)
mw, mh = int(w*0.5), int(h*0.5)

def score(dx, dy):
    tot = n = 0
    for y in range(my, my+mh, 3):
        for x in range(mx, mx+mw, 3):
            sx, sy = x+dx, y+dy
            if 0 <= sx < w and 0 <= sy < h:
                tot += abs(ap[x, y] - bp[sx, sy]); n += 1
    return tot/n if n else 9e9

# --- 第1段階: 縮小版で大まかな位置を掴む(4px刻み) ---
best, bdx, bdy = 9e9, 0, 0
# 縮上後の探索範囲。1/4に縮小しているので元解像度では±48px。
#
# 【広げすぎない理由】
# R=24(±96px)まで広げたところ、遠く離れた位置で偶然模様が一致し、
# ドリフトのない映像を「62pxずれている」と誤判定した。
# LTXのドリフトは12秒で数十px程度なので、±48pxで足りる。
R = 12
for dy in range(-R, R+1):
    for dx in range(-R, R+1):
        s = score(dx, dy)
        if s < best:
            best, bdx, bdy = s, dx, dy

# --- 第2段階: 原寸でその周辺を1px刻みで詰める ---
# 数pxのずれでも継ぎ目のカクッとして見えるため、ここまで追い込む
try:
    fa = Image.open('drift_a_full.png').convert('L')
    fb = Image.open('drift_b_full.png').convert('L')
    fw, fh = fa.size
    fap, fbp = fa.load(), fb.load()
    # 【測る範囲を広げ、細かく見る理由】
    # 中央50%・6px飛ばしでは、建物の柱のような細い輪郭を捉えきれず
    # 1px単位のずれが残っていた。
    # 範囲を70%に広げ、3px飛ばしにして精度を上げる。
    # サンプル数は約4倍になるが、測定は1クリップにつき1回なので影響は小さい。
    fmx, fmy = int(fw*0.15), int(fh*0.15)
    fmw, fmh = int(fw*0.7), int(fh*0.7)

    def fscore(dx, dy):
        tot = n = 0
        for y in range(fmy, fmy+fmh, 3):
            for x in range(fmx, fmx+fmw, 3):
                sx, sy = x+dx, y+dy
                if 0 <= sx < fw and 0 <= sy < fh:
                    # 【平均差を使う理由】
                    # 二乗誤差も試したが、湯気のように大きく変化する部分が
                    # 強調されすぎて、まったく違う位置を「一致」と誤判定した
                    # (2pxのずれを54pxと誤検出した)。平均差のほうが安定する。
                    tot += abs(fap[x, y] - fbp[sx, sy]); n += 1
        return tot/n if n else 9e9

    # 縮小版の推定を中心に、その周辺を1px刻みで探す。
    # 縮小版は4px刻みなので誤差は最大±4pxだが、
    # 二乗誤差は谷が鋭いぶん局所解に落ちやすいので、
    # 余裕をみて±6pxまで見る。
    cx, cy = bdx*4, bdy*4
    fbest, fdx, fdy = 9e9, cx, cy
    for dy in range(cy-6, cy+7):
        for dx in range(cx-6, cx+7):
            s = fscore(dx, dy)
            if s < fbest:
                fbest, fdx, fdy = s, dx, dy
    print(f"{fdx} {fdy}")
except Exception:
    print(f"{bdx*4} {bdy*4}")
DRIFTPY
}

DRIFT_ZOOM_PCT=""
if [ "${DRIFT_CORRECTION_ENABLED:-1}" = "1" ]; then
  echo "ループクリップのドリフトを測って打ち消します..."
  for ((i=0; i<CLIP_COUNT; i++)); do
    DRIFT=$(measure_drift_ "stage_clip_$i.mp4" 2>/dev/null | tail -1)
    DX=$(echo "$DRIFT" | awk '{print ($1=="")?0:$1}')
    DY=$(echo "$DRIFT" | awk '{print ($2=="")?0:$2}')

    # 【1pxは無視する】
    # 映像には湯気や水面の動きがあるため、測定には1px程度の揺らぎが出る。
    # ドリフトのない素材でも1pxと出ることがあり、それを補正しても意味がない。
    # 一方2px以上のずれは12秒ごとの「カクッ」として知覚されるので補正する。
    # 測定精度を上げたので、1pxのずれも補正する。
    # 12秒ごとに1pxでも戻ると、直線の多い建物では気づかれることがある。
    if [ "$DX" = "0" ] && [ "$DY" = "0" ]; then
      echo "  クリップ$((i+1)): ドリフトはありません"
      continue
    fi

    CD=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "stage_clip_$i.mp4")
    CWID=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "stage_clip_$i.mp4")
    CHGT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "stage_clip_$i.mp4")

    ABSX=$(awk -v v="$DX" 'BEGIN{printf "%d", (v<0)?-v:v}')
    ABSY=$(awk -v v="$DY" 'BEGIN{printf "%d", (v<0)?-v:v}')
    MARGIN=6
    CW=$(( (CWID - ABSX - MARGIN*2) / 2 * 2 ))
    CH=$(( (CHGT - ABSY - MARGIN*2) / 2 * 2 ))
    XMAX=$(( CWID - CW )); YMAX=$(( CHGT - CH ))

    # 動く方向を考え、枠内に収まる位置から始める
    if [ "$DX" -lt 0 ]; then SX=$XMAX; else SX=0; fi
    if [ "$DY" -lt 0 ]; then SY=$YMAX; else SY=0; fi

    PCT=$(awk -v w="$CWID" -v cw="$CW" 'BEGIN{printf "%.1f", (w/cw-1)*100}')
    echo "  クリップ$((i+1)): ドリフト x=${DX}px y=${DY}px → 拡大${PCT}%で打ち消します"

    if ffmpeg -y -i "stage_clip_$i.mp4" \
         -vf "crop=${CW}:${CH}:x='clip(${SX}+(${DX})*t/${CD},0,${XMAX})':y='clip(${SY}+(${DY})*t/${CD},0,${YMAX})',scale=${CWID}:${CHGT}" \
         -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -r 30 -an "stage_fix_$i.mp4" 2>"err_drift_$i.log"; then
      mv "stage_fix_$i.mp4" "stage_clip_$i.mp4"
      DRIFT_ZOOM_PCT="$PCT"
    else
      echo "    補正に失敗したため、そのまま使います"
      tail -3 "err_drift_$i.log" 2>/dev/null || true
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
# ループの継ぎ目を溶かす秒数
#
# 【長くしている理由】
# LTXはカメラを固定しろと指示しても必ずドリフトする。
# vidstabで打ち消そうとすると拡大が必要になり、画角が削られる。
# end_image_urlで固定すると湯や湯気まで止まってしまう。
#
# そこで発想を変え、ドリフトはそのまま残して
# 「継ぎ目を長く溶かす」ことで、位置の戻りを時間に分散させる。
# 6秒かけて溶ければ、カクッとした飛びではなく
# ゆっくりした揺り戻しとして知覚される。
#
#   3 … 継ぎ目が短い(現在)
#   6 … 戻りを引き伸ばす案。カクッは減ったが、ずれた2枚が長時間重なるため
#        建物の柱や庇の輪郭が二重に見えてしまい、かえって目立った
#
# 結局「ずれを時間で誤魔化す」のは無理があり、
# vidstabでずれ自体を消す方針に戻した。
# ※長くするほどループ周期は短くなる(15.3秒 − この値)
# 【1秒にしている理由】
# ループの継ぎ目は、末尾と先頭をこの秒数だけ重ねて溶かしている。
# 重なっている間は2枚の映像が同時に見えるため、
#   ・建物の輪郭が二重に見える(残像)
#   ・湯気が2枚ぶん見えて量が増える
# という副作用がある。長いほどこれが目立つ。
#
# 以前は3秒にしていたが、それはカメラのドリフトによる位置ずれを
# 時間をかけて誤魔化す必要があったため。
# ドリフトを実測して打ち消す方式に変えた結果、ずれは0pxになったので、
# 重ねる必要がなくなった。最小限の1秒に縮める。
#
#   3秒 … ずれを誤魔化していた頃の値。残像と湯気の増減が目立つ
#   1秒 … 短くしたが、それでも重なりによる残像がわずかに残った
#   0秒 … 重ねずに直結する(現在)
#
# 【0でつながる理由】
# ループ用クリップは「先頭と末尾が同じ絵になるよう」ドリフトを打ち消してある。
# 位置が完全に一致しているなら、重ねて溶かす必要はなく、
# そのまま繋いだほうが残像も湯気の増減も起こらない。
XFADE_LOOP=0

# 導入部とループの境目を溶かす秒数
#
# ループの継ぎ目(XFADE_LOOP)とは別に設定する。
# 導入部の終盤はカメラが停止しているため、長く溶かすと二重像が
# 動かないまま居座り、「残像」として見えてしまう。
# 1秒程度なら、残像と認識される前に切り替わりが終わる。
# 導入部とループの境目を溶かす秒数
#
# 1秒だと変化が急で、境目が二重像として見えることがあったため2秒に延ばした。
XFADE_INTRO=2

# 導入部の冒頭から切り落とす秒数
#
# LTXは生成の最初の数秒で急旋回し、強いモーションブラーを出すことがある。
# ここが視聴者に画面酔いを起こさせる原因になるため、物理的に捨てる。
#   0   … 切らない(以前の挙動)
#   3   … 冒頭3秒を捨てる(急旋回はほぼこの範囲に収まる)
INTRO_HEAD_CUT=3

# 導入部の末尾から切り落とす秒数
#
# 【0にしている理由】
# 終端の崩れを消すため一度2秒切ってみたが、ワープが起きて悪化した。
#
# ループ用クリップは「導入部の“元の”最終フレーム」を起点に生成されている。
# 末尾を切ると導入部はその2秒手前で終わるのに、ループは2秒先の絵から始まるため、
# 境目で画が飛ぶ。冒頭カットと違い、末尾は勝手に切ってはいけない。
#
# 終端の崩れは XFADE_INTRO(境目を溶かす秒数)を長くして対処する。
#   0 … 切らない(現在)
#   ※もし切りたくなった場合は、切った後の最終フレームを抽出し直して
#     ループクリップも作り直す必要がある
INTRO_TAIL_CUT=0

# レイヤー合成で使う「ループ1周期の長さ」。加工が済んだ時点で設定される。
SEAMLESS_DUR=""

echo "クリップをシームレスループに加工します..."
for ((i=0; i<CLIP_COUNT; i++)); do
  CLIP_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "stage_clip_$i.mp4")
  BODY_END=$(awk "BEGIN{print $CLIP_DUR - $XFADE_LOOP}")

  # 【XFADE_LOOP=0 のとき】
  # 重ねる処理(xfade)は長さ0では動かない。
  # ドリフトを打ち消して先頭と末尾が一致しているなら、
  # 加工せずそのまま繋げばよいので、クリップをそのまま使う。
  if awk "BEGIN{exit !($XFADE_LOOP < 0.01)}"; then
    cp "stage_clip_$i.mp4" "stage_loop_$i.mp4"
    LOOP_DUR="$CLIP_DUR"
    SEAMLESS_DUR="$LOOP_DUR"
    LOOP_HEAD_FILE=""
    echo "  クリップ$((i+1)): 重ねずにそのまま繋ぎます(${CLIP_DUR}秒)"
    continue
  fi

  if ffmpeg -y -i "stage_clip_$i.mp4" -filter_complex \
      "[0:v]trim=start=${XFADE_LOOP}:end=${BODY_END},setpts=PTS-STARTPTS[main];\
[0:v]trim=start=${BODY_END},setpts=PTS-STARTPTS[tail];\
[0:v]trim=start=0:end=${XFADE_LOOP},setpts=PTS-STARTPTS[head];\
[tail][head]xfade=transition=fade:duration=${XFADE_LOOP}:offset=0[wrap];\
[main][wrap]concat=n=2:v=1[out]" \
      -map "[out]" -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -r 30 -an "stage_loop_$i.mp4" 2>"err_loop_$i.log"; then
    LOOP_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "stage_loop_$i.mp4")
    echo "  クリップ$((i+1)): シームレスループ化しました(${CLIP_DUR}秒 → ${LOOP_DUR}秒)"
    # レイヤー合成で「1周期だけ合成して繰り返す」ために、1周期の長さを覚えておく
    SEAMLESS_DUR="$LOOP_DUR"

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
# 拡大率はクリップごとに実測したドリフト量から決まるので、
# 補正時に記録した DRIFT_ZOOM_PCT を使う(補正しなかった場合は拡大なし)。
if [ -n "${DRIFT_ZOOM_PCT:-}" ] && awk -v p="${DRIFT_ZOOM_PCT:-0}" 'BEGIN{exit !(p > 0.05)}'; then
  INTRO_ZOOM_VF="crop=iw/(1+${DRIFT_ZOOM_PCT}/100):ih/(1+${DRIFT_ZOOM_PCT}/100),scale=1920:1080,"
  echo "導入部にもループと同じ${DRIFT_ZOOM_PCT}%の拡大をかけます(切り替わりで画の大きさを揃えるため)"
else
  INTRO_ZOOM_VF=""
  echo "ドリフト補正による拡大がないため、導入部はそのまま使います"
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

# ---- レイヤー合成: 建物と空を静止画に固定する ----
#
# 【なぜ必要か】
# LTXのクリップはカメラが必ずドリフトし、ループの継ぎ目で建物の輪郭がずれる。
# vidstab(画角が削れる)・end_image_url(湯が止まる)・長いクロスフェード(二重像)、
# どれも別の問題を生んだ。
#
# 【仕組み】Lo-fiアニメと同じ「動く部分だけを動かす」方式
#   ベース   : stage1の静止画      … 建物・空・雲海。完全静止なのでずれようがない
#   湯の領域 : LTXのループクリップ … Geminiが特定した座標だけ、ぼかしたマスクで重ねる
#              水は形が不定形なので、領域内のドリフトも継ぎ目も知覚できない
#   星       : ffmpegで明滅を描く  … LTXは輝度の変化を表現できないため
#
# LAYER_REGIONS(Geminiが返した領域JSON)と BASE_IMAGE_URL が
# 渡されたときだけ動く。無ければ従来どおり。
# ---- 静止画ベースのループを作る(手描きのループ動画と同じ発想) ----
#
# 【なぜこの方式か】
# LTXが生成した動画はカメラが必ずドリフトし、後処理では消しきれなかった。
# 一方、手作業でループ動画を作る人は「動かない背景」に「動くもの」を
# 重ねて作っている。だからループも完璧だしカメラも動かない。
#
# ここでは同じことをする:
#   背景   … stage1の静止画。完全静止なのでドリフトも歪みも起こりえない
#   湯の落下 … Pexelsの流水素材を、Geminiが特定した石樋の位置に重ねる
#   湯気     … 同じく水面に重ねる
#   星       … ffmpegで明滅を描く
#
# 素材自体がループするので、継ぎ目も原理的に存在しない。
# TikTok用の雨・雪と同じ手法を、画面全体ではなく領域限定で使っている。
# 【無効にしている理由】
# 静止画にPexelsの流水・湯気素材を重ねてループを作る方式を試したが、
# 実写素材とAI画像の質感が合わず、貼り付けたように見えて使えなかった。
#
# 雨や雪が馴染むのは「画面全体に散らばる小さな粒」だからで、
# 滝のように特定の場所に特定の形で存在するものは、
# 角度・水量・光の当たり方まで一致しないと不自然になる。
#
# コードは残してあるので、1 に戻せば再び試せる。
STILL_LOOP_ENABLED=0

STILL_LOOP_APPLIED=false
if [ "${STILL_LOOP_ENABLED:-0}" = "1" ] && [ -n "${LAYER_REGIONS:-}" ] && [ -n "${BASE_IMAGE_URL:-}" ] && command -v jq >/dev/null 2>&1; then
  echo "静止画ベースのループを作ります(背景は完全静止)..."
  STILL_OK=true

  download_or_die_ "$BASE_IMAGE_URL" still_base.bin || STILL_OK=false
  if [ "$STILL_OK" = true ]; then
    ffmpeg -y -i still_base.bin \
      -vf "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,setsar=1" \
      -frames:v 1 still_base.png 2>err_stillbase.log || STILL_OK=false
  fi

  # 1周期の長さ。素材の長さに合わせると継ぎ目が出ないので、素材優先で決める
  STILL_UNIT=12

  # ---- 重ねるレイヤーを組み立てる ----
  STILL_INPUTS=()
  STILL_FILTER=""
  STILL_LAST="bg"
  OVERLAY_IDX=1   # 0番は静止画

  add_overlay_() {
    # $1=素材URL $2=領域キー $3=ぼかし量 $4=不透明度
    local URL="$1" KEY="$2" BLUR="$3" OPA="$4"
    [ -z "$URL" ] || [ "$URL" = "none" ] && return 1

    local RECT
    RECT=$(echo "$LAYER_REGIONS" | jq -r --arg k "$KEY" '.[$k] // empty | "\(.x) \(.y) \(.w) \(.h)"' 2>/dev/null)
    [ -z "$RECT" ] && return 1

    local RX RY RW RH PX PY PW PH
    read RX RY RW RH <<< "$RECT"
    PX=$(awk "BEGIN{v=1920*$RX/100; if(v<0)v=0; printf \"%d\", v}")
    PY=$(awk "BEGIN{v=1080*$RY/100; if(v<0)v=0; printf \"%d\", v}")
    PW=$(awk "BEGIN{v=1920*$RW/100; if(v<8)v=8; printf \"%d\", v}")
    PH=$(awk "BEGIN{v=1080*$RH/100; if(v<8)v=8; printf \"%d\", v}")

    if ! download_or_die_ "$URL" "ov_${KEY}.mp4"; then return 1; fi

    STILL_INPUTS+=(-stream_loop -1 -i "ov_${KEY}.mp4")
    # 素材を領域の大きさに合わせ、黒いキャンバスの該当位置に置いてから
    # screenブレンドで重ねる(黒は素通りするので、明るい水や湯気だけが乗る)
    STILL_FILTER="${STILL_FILTER}[${OVERLAY_IDX}:v]scale=${PW}:${PH},format=gbrp[ovs${OVERLAY_IDX}];"
    STILL_FILTER="${STILL_FILTER}color=c=black:s=1920x1080:d=${STILL_UNIT}:r=30,format=gbrp[cv${OVERLAY_IDX}];"
    STILL_FILTER="${STILL_FILTER}[cv${OVERLAY_IDX}][ovs${OVERLAY_IDX}]overlay=x=${PX}:y=${PY}[ovp${OVERLAY_IDX}];"
    STILL_FILTER="${STILL_FILTER}[ovp${OVERLAY_IDX}]gblur=sigma=${BLUR}[ovb${OVERLAY_IDX}];"
    STILL_FILTER="${STILL_FILTER}[${STILL_LAST}][ovb${OVERLAY_IDX}]blend=all_mode=screen:all_opacity=${OPA}[bl${OVERLAY_IDX}];"
    STILL_LAST="bl${OVERLAY_IDX}"
    echo "  ${KEY} を重ねます (x=${PX} y=${PY} w=${PW} h=${PH})"
    OVERLAY_IDX=$((OVERLAY_IDX + 1))
    return 0
  }

  if [ "$STILL_OK" = true ]; then
    STILL_FILTER="[0:v]format=gbrp[bg];"
    add_overlay_ "${WATER_FALL_URL:-}" "water_fall" 3 0.85 || true
    add_overlay_ "${STEAM_URL:-}" "water_surface" 12 0.35 || true

    if [ "$STILL_LAST" = "bg" ]; then
      echo "  重ねる素材がないため、静止画ベースのループは作りません"
      STILL_OK=false
    fi
  fi

  # ---- 星の明滅 ----
  if [ "$STILL_OK" = true ]; then
    SKY=$(echo "$LAYER_REGIONS" | jq -r '.sky // empty | "\(.x) \(.y) \(.w) \(.h)"' 2>/dev/null)
    if [ -n "$SKY" ]; then
      read SX SY SW SH <<< "$SKY"
      STAR_B=""
      for ((s=1; s<=28; s++)); do
        eval "$(awk -v i=$s -v sx=$SX -v sy=$SY -v sw=$SW -v sh=$SH -v P=$STILL_UNIT 'BEGIN{
          srand(i*7919);
          x=int(1920*(sx+rand()*sw)/100);
          y=int(1080*(sy+rand()*sh*0.85)/100);
          n=int(2+rand()*5); p=P/n; ph=rand()*6.28; th=0.35+rand()*0.35;
          printf "STX=%d; STY=%d; STP=%.4f; STPH=%.2f; STTH=%.2f", x, y, p, ph, th
        }')"
        STAR_B="${STAR_B}drawbox=x=${STX}:y=${STY}:w=2:h=2:color=white:t=fill:enable='gt(sin(2*PI*t/${STP}+${STPH}),${STTH})',"
      done
      STILL_FILTER="${STILL_FILTER}color=c=black:s=1920x1080:d=${STILL_UNIT}:r=30[stb];"
      STILL_FILTER="${STILL_FILTER}[stb]${STAR_B%,},gblur=sigma=1.1,format=gbrp[stars];"
      STILL_FILTER="${STILL_FILTER}[${STILL_LAST}][stars]blend=all_mode=screen[withstars];"
      STILL_LAST="withstars"
      echo "  星の明滅を28個配置しました"
    fi
    STILL_FILTER="${STILL_FILTER}[${STILL_LAST}]format=yuv420p[stillout]"
  fi

  # ---- 1周期を作って、必要な長さまで繰り返す ----
  if [ "$STILL_OK" = true ]; then
    if ffmpeg -y -loop 1 -i still_base.png "${STILL_INPUTS[@]}" \
         -filter_complex "$STILL_FILTER" -map "[stillout]" \
         -t "$STILL_UNIT" -r 30 \
         -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -an still_unit.mp4 2>err_still.log; then

      LOOP_TARGET=$(ffprobe -v error -show_entries format=duration -of csv=p=0 loop_video.mp4)
      if ffmpeg -y -stream_loop -1 -i still_unit.mp4 -t "$LOOP_TARGET" -c copy still_loop.mp4 2>err_stillloop.log; then
        mv still_loop.mp4 loop_video.mp4
        STILL_LOOP_APPLIED=true
        echo "  静止画ベースのループを作りました(背景は完全静止・継ぎ目なし)"
      else
        echo "  繰り返しに失敗したため、従来のループを使います"
        tail -5 err_stillloop.log || true
      fi
    else
      echo "  静止画ベースのループ作成に失敗したため、従来のループを使います"
      tail -5 err_still.log || true
    fi
  fi
fi

# ---- レイヤー合成の有効/無効 ----
#
# 【無効にしている理由】
# 「建物と空は静止画、湯だけ動画」という切り分けを試したが、
# 静止画とLTX動画は元々別物なので、マスクの境目で
# 「動かない建物」と「動く建物」が混ざり、かえって歪みが悪化した。
# マスクのぼかし幅(50px)が広いぶん、その帯全体がぐにゃつく。
#
# Lo-fi動画が成立するのは最初からレイヤーごとに描かれているからで、
# 完成した映像を後から切り分けるのとは根本的に違った。
#
# コードは残してあるので、1 に戻せば再び試せる。
LAYER_COMPOSITE_ENABLED=0

LAYER_APPLIED=false
if [ "$LAYER_COMPOSITE_ENABLED" != "1" ]; then
  if [ -n "${LAYER_REGIONS:-}" ]; then
    echo "レイヤー合成は無効に設定されているため、従来方式でレンダリングします"
  fi
elif [ -n "${LAYER_REGIONS:-}" ] && [ -n "${BASE_IMAGE_URL:-}" ] && command -v jq >/dev/null 2>&1; then
  echo "レイヤー合成を行います(建物と空を静止画に固定)..."
  LAYER_OK=true

  # ベースの静止画
  download_or_die_ "$BASE_IMAGE_URL" base_image.bin || LAYER_OK=false
  if [ "$LAYER_OK" = true ]; then
    ffmpeg -y -i base_image.bin \
      -vf "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,setsar=1" \
      -frames:v 1 base_image.png 2>err_base.log || LAYER_OK=false
  fi

  # 湯の領域からマスクを作る(白=クリップを見せる場所)
  if [ "$LAYER_OK" = true ]; then
    MASK_BOXES=""
    for KEY in water_fall water_surface; do
      RECT=$(echo "$LAYER_REGIONS" | jq -r --arg k "$KEY" '.[$k] // empty | "\(.x) \(.y) \(.w) \(.h)"' 2>/dev/null)
      if [ -n "$RECT" ]; then
        read RX RY RW RH <<< "$RECT"
        # パーセント座標(0-100)をピクセルへ。少し余白を持たせて自然に馴染ませる
        PX=$(awk "BEGIN{v=1920*($RX-2)/100; if(v<0)v=0; printf \"%d\", v}")
        PY=$(awk "BEGIN{v=1080*($RY-2)/100; if(v<0)v=0; printf \"%d\", v}")
        PW=$(awk "BEGIN{v=1920*($RW+4)/100; printf \"%d\", v}")
        PH=$(awk "BEGIN{v=1080*($RH+4)/100; printf \"%d\", v}")
        MASK_BOXES="${MASK_BOXES}drawbox=x=${PX}:y=${PY}:w=${PW}:h=${PH}:color=white:t=fill,"
        echo "  湯の領域(${KEY}): x=${PX} y=${PY} w=${PW} h=${PH}"
      fi
    done

    if [ -z "$MASK_BOXES" ]; then
      echo "  湯の領域が特定されていないため、レイヤー合成を飛ばします"
      LAYER_OK=false
    else
      # 縁を大きくぼかして、静止画とクリップの境目を溶かす
      ffmpeg -y -f lavfi -i "color=c=black:s=1920x1080" \
        -vf "${MASK_BOXES}gblur=sigma=50,format=gray" \
        -frames:v 1 layer_mask.png 2>err_mask.log || LAYER_OK=false
    fi
  fi

  # 星の明滅を組み立てる(空の領域に小さな点を散らし、周期をずらして瞬かせる)
  STAR_BOXES=""
  if [ "$LAYER_OK" = true ]; then
    SKY=$(echo "$LAYER_REGIONS" | jq -r '.sky // empty | "\(.x) \(.y) \(.w) \(.h)"' 2>/dev/null)
    if [ -n "$SKY" ]; then
      read SX SY SW SH <<< "$SKY"
      STAR_COUNT=28
      for ((s=1; s<=STAR_COUNT; s++)); do
        # 固定シードの擬似乱数で、毎回同じ配置になるようにする(再現性のため)
        #
        # 【明滅の周期を1周期の約数にする】
        # 合成は1周期分だけ行い、それをコピーで繰り返す方式にしたため、
        # 星の周期が1周期を割り切らないと、繰り返しの継ぎ目で明滅が飛ぶ。
        # 1周期に2〜6回瞬く形にして、必ず割り切れるようにする。
        eval "$(awk -v i=$s -v sx=$SX -v sy=$SY -v sw=$SW -v sh=$SH -v P=$UNIT_DUR 'BEGIN{
          srand(i*7919);
          x=int(1920*(sx+rand()*sw)/100);
          y=int(1080*(sy+rand()*sh*0.85)/100);
          n=int(2+rand()*5);           # 1周期に2〜6回瞬く
          p=P/n;                       # 周期は1周期の約数になる
          ph=rand()*6.28;              # 位相をばらす
          th=0.35+rand()*0.35;         # 点灯している時間の割合もばらす
          printf "STX=%d; STY=%d; STP=%.4f; STPH=%.2f; STTH=%.2f", x, y, p, ph, th
        }')"
        STAR_BOXES="${STAR_BOXES}drawbox=x=${STX}:y=${STY}:w=2:h=2:color=white:t=fill:enable='gt(sin(2*PI*t/${STP}+${STPH}),${STTH})',"
      done
      echo "  星の明滅: ${STAR_COUNT}個を空の領域に配置"
    fi
  fi

  # 合成の実行
  #
  # 【1周期だけ合成してコピーで繰り返す】
  # ループ部分は同じ映像の繰り返しなので、全長を合成する必要がない。
  # 1周期(12秒前後)だけ合成し、残りは再エンコードなしのコピーで繰り返す。
  # 全長を合成すると1時間版で80分以上かかり、GitHub Actionsが
  # タイムアウトしていた(実際に20分で失敗した)。この方式なら17秒程度で済む。
  if [ "$LAYER_OK" = true ]; then
    LOOP_DUR_ALL=$(ffprobe -v error -show_entries format=duration -of csv=p=0 loop_video.mp4)

    # 1周期の長さ = クリップ長 - ループの継ぎ目
    # 段階が複数ある場合は周期がひとつに定まらないため、全長を合成する
    if [ "$CLIP_COUNT" -eq 1 ] && [ -n "$SEAMLESS_DUR" ]; then
      UNIT_DUR=$(awk "BEGIN{v=$SEAMLESS_DUR; if(v<=0 || v>$LOOP_DUR_ALL) v=$LOOP_DUR_ALL; printf \"%.3f\", v}")
      echo "  1周期(${UNIT_DUR}秒)だけ合成し、残りは繰り返します"
    else
      UNIT_DUR="$LOOP_DUR_ALL"
      echo "  段階が複数あるため全長(${UNIT_DUR}秒)を合成します"
    fi

    if [ -n "$STAR_BOXES" ]; then
      # 【色形式を揃える】
      # blendは入力の色形式が違うと色差の扱いを誤り、
      # 灰色がマゼンタになるなど画面全体の色が壊れる(実際に発生した)。
      # 両方をgbrpに揃えてからblendし、最後にyuv420pへ戻す。
      STAR_CHAIN=";color=c=black:s=1920x1080:d=${UNIT_DUR}:r=30[sb];[sb]${STAR_BOXES%,},gblur=sigma=1.1,format=gbrp[stars];[merged]format=gbrp[mg];[mg][stars]blend=all_mode=screen,format=yuv420p[outv]"
    else
      STAR_CHAIN=";[merged]format=yuv420p[outv]"
    fi

    # 【maskedmergeではなくalphamerge+overlayを使う】
    # maskedmergeは3入力の画素形式が揃っていないと正しく動かない
    # (検証環境で、マスクの外までクリップが見える誤動作を確認した)。
    # クリップにマスクをアルファとして焼き込み、ベースに重ねる方式なら確実。
    if ffmpeg -y -i loop_video.mp4 -loop 1 -i base_image.png -loop 1 -i layer_mask.png -filter_complex \
        "[0:v]format=rgba[clip];[2:v]format=gray[m];[clip][m]alphamerge[ca];[1:v]format=rgba[base];[base][ca]overlay=format=rgb[merged]${STAR_CHAIN}" \
        -map "[outv]" -t "$UNIT_DUR" -r 30 \
        -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -an unit_layered.mp4 2>err_layer.log; then

      # 合成した1周期を、元の長さになるまでコピーで繰り返す(再エンコードなしなので一瞬)
      if ffmpeg -y -stream_loop -1 -i unit_layered.mp4 -t "$LOOP_DUR_ALL" -c copy loop_layered.mp4 2>err_layerloop.log; then
        mv loop_layered.mp4 loop_video.mp4
        LAYER_APPLIED=true
        echo "  レイヤー合成が完了しました(建物と空は静止画、湯の領域だけ動画)"
      else
        echo "  合成した1周期の繰り返しに失敗したため、従来のループをそのまま使います"
        tail -5 err_layerloop.log || true
      fi
    else
      echo "  レイヤー合成に失敗したため、従来のループをそのまま使います"
      tail -5 err_layer.log || true
    fi
  fi
fi

# ---- ループ部分に夜空のゆらぎを足す ----
#
# 星の瞬きも炎の揺らめきもLTXが表現しなかったため、後処理で補う。
# 0にすると無効。0.015 で±1.5%の明るさの揺らぎ。
SHIMMER_STRENGTH=0.015

# 【レイヤー合成が動いたときは省く】
# 合成側で星の明滅を描いているので、画面全体のゆらぎまで足すと過剰になる。
# また1時間ぶんの全長に掛けると処理が重く、タイムアウトの原因にもなる。
if [ "${LAYER_APPLIED:-false}" = true ] || [ "${STILL_LOOP_APPLIED:-false}" = true ]; then
  SHIMMER_STRENGTH=0
  echo "星の明滅を描いたため、画面全体のゆらぎは省きます"
fi

if awk "BEGIN{exit !($SHIMMER_STRENGTH > 0.0001)}"; then
  echo "夜空のゆらぎを加えます(明るさ±$(awk "BEGIN{printf \"%.1f\", $SHIMMER_STRENGTH*100}")%)..."

  # 周期の違う3つの波を重ねて不規則なゆらぎを作る
  #   4.7秒 / 7.3秒 / 11.1秒 … 互いに割り切れない周期にして繰り返しを感じさせない
  #
  # 【geqではなくeqを使う理由】
  # geq は1画素ずつ式を評価するため、1920x1080の1時間動画では
  # 現実的な時間で終わらない。eq の brightness は
  # フレームごとに1回だけ評価すればよく、桁違いに速い。
  SHIMMER_EXPR="${SHIMMER_STRENGTH}*(0.5*sin(2*PI*t/4.7)+0.3*sin(2*PI*t/7.3+1.2)+0.2*sin(2*PI*t/11.1+2.7))"

  if ffmpeg -y -i loop_video.mp4 \
       -vf "eq=brightness='${SHIMMER_EXPR}':eval=frame" \
       -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -an loop_shimmer.mp4 2>err_shimmer.log; then
    mv loop_shimmer.mp4 loop_video.mp4
    echo "  夜空のゆらぎを加えました"
  else
    echo "  ゆらぎの追加に失敗したため、そのまま使います"
    tail -3 err_shimmer.log || true
    rm -f loop_shimmer.mp4
  fi
fi

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
  # 冒頭カットぶんに加えて、末尾の崩れた区間も差し引く
  INTRO_KEEP=$(awk "BEGIN{v=$INTRO_TRIM - $INTRO_HEAD_CUT - $INTRO_TAIL_CUT; if(v<1) v=$INTRO_TRIM - $INTRO_HEAD_CUT; print v}")
  if awk "BEGIN{exit !($INTRO_TAIL_CUT > 0.05)}"; then
    echo "  末尾${INTRO_TAIL_CUT}秒も切り落とします(終端のフリッカーとブレ対策)"
  fi
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
INTRO_EFFECTIVE=$(awk "BEGIN{v=$INTRO_DURATION - $INTRO_HEAD_CUT - $INTRO_TAIL_CUT; if(v<3) v=$INTRO_DURATION - $INTRO_HEAD_CUT; print v}")
echo "音のタイミング基準: ${INTRO_EFFECTIVE}秒(指定${INTRO_DURATION}秒 − 冒頭${INTRO_HEAD_CUT}秒 − 末尾${INTRO_TAIL_CUT}秒)"

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
  # 【調整の経緯】
  # 当初は 1800Hz / 音量0.32 にしていたが、冒頭のBGMが控えめすぎた。
  # YouTube以外(Shorts・TikTok)にも載せることを考えると、
  # 冒頭からしっかり音楽が聞こえたほうがよい。
  # 帯域と音量を上げ、「小さい→大きい」ではなく
  # 「そこそこ聞こえる→満ちる」という変化にする。
  BGM_INDOOR_LOWPASS=3000    # 室内で残す帯域の上限(下げるほど編成が薄く聴こえる)
  BGM_INDOOR_VOLUME=0.55     # 室内でのBGM音量(屋外は0.8)
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
  # 【BGMと効果音は別扱いにする】
  #
  # BGMは冒頭から聞こえてほしい(どのプラットフォームでも掴みが要るため)ので
  # 室内でも音量を上げてある。
  #
  # 一方、効果音は完全な無音から始める。
  # 導入部の開始位置は建物のいちばん奥で、露天風呂からかなり離れている。
  # そこで湯の音が聞こえるのは物理的におかしいため、
  # 戸に近づくにつれて初めて聞こえ始める形にする。
  #   0.45 … BGMに合わせて上げた値(室内で聞こえすぎた)
  #   0.18 … 気配は感じる程度。それでも遠すぎる場所では不自然
  #   0    … 完全な無音から始める(現在)
  DIST_FAR_VOL=0
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
