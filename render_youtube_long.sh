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
# ドリフト対策は「実測して線形に打ち消す」方式に一本化する。
#
# 【調整の目安】
#   1.0  … 等速(LTXが生成したまま。雲が早回しに見える)
#   0.6  … 6秒→10秒。雲は落ち着くが、導入部のほぼ静止した雲とはまだ差がある
#   0.4  … 6秒→15秒。雲の動きが1/3以下になり、導入部との差がほぼ分からなくなる
#          湯気や水面もゆっくりになるが、放置動画ではむしろ落ち着いて見える
#
# 【トレードオフ】
# 遅くするほどループ周期が長くなり、繰り返し感が減る。
# しかし遅すぎると、石樋から落ちる水のような速い動きが
# 止まって見えてしまう(0.4で実際にそうなった)。
#
#   0.4 … 周期15.3秒。水はやや遅いが、繰り返しが目立たない(現在)
#   0.6 … 周期10.2秒。水は自然に流れるが、10秒ごとの繰り返しが強く出た
#
# ※この値を変えたら render.yml の LOOP_PERIOD も直すこと
#   (Geminiの動画チェックが1周期分を切り出すのに使っている)
# ループクリップの再生速度
#
# 【空を止めたので戻した】
# 遅くしていたのは雲を落ち着かせるためだったが、
# 空を固定した今はその必要がない。むしろ遅いままだと
# 湯が「流れている」ではなく「垂れている」ように見える。
#
#   1.0  … 等速。湯はいちばん自然だが、周期が6秒と短い
#   0.6  … 6.1秒→10.2秒。湯は自然なまま、周期も倍になる(現在)
#   0.4  … 6.1秒→15.3秒。周期は長いが湯がやや遅い
#   0.3  … 湯が垂れて見え始める
#
# 【補間の負担】
# 0.6なら25fpsの素材から実質15fps、30fpsを作るのに
# 2枚に1枚が生成フレーム。0.3のときの4枚に3枚より格段に軽く、
# にじみや歪みも出にくい。
#
# ※この値を変えたら render.yml の LOOP_PERIOD も直すこと
#   (0.6なら周期は約8秒 = 10.2秒 − 重ねる2秒)
LOOP_SPEED=0.6

# 遅くしたぶんの隙間を、どうやって埋めるか
#
# 【これがカクつきの正体だった】
# 以前は setpts で引き伸ばしたあと fps=30 に合わせるだけだった。
# これは足りないフレームを「直前のフレームの複製」で埋める処理で、
# 0.4倍だと1枚を2回・3回と交互に繰り返すことになる。
# 実測すると出来上がったクリップの6割が直前とまったく同じフレームで、
# 動きは毎秒30回ではなく12回しか進まない。しかも刻みが不均等なため、
# ループ部分がずっとカクカクして見えていた。
#
#   mci   … 前後のフレームから動きを読み取り、本当の中間フレームを作る(既定)
#           1080p・15秒で6分ほどかかるが、動きが滑らかになる
#   blend … 前後を重ねて埋める。5秒で終わるが、落ちる湯に二重像が出る
#   dup   … 従来どおり複製で埋める(カクつく。比較用に残してある)
LOOP_SLOWDOWN_MODE=mci

# ドリフト補正を使うかどうか
#
# 1 … 使う(既定)。周期ごとの拡大・平行移動を打ち消す
# 0 … 使わない。補正の影響を切り分けたいときにここを0にする
#
# カクつきの原因は上の LOOP_SLOWDOWN_MODE 側だったが、
# 万一まだ気になる場合は、ここを0にして比べれば
# どちらが効いているかがはっきりする(追加費用はかからない)。
DRIFT_CORRECTION_ENABLED=1

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

# vidstabはもう使っていない(ドリフトは実測して線形に打ち消す方式に変更)。
# 変数だけ残してあるのは、他の箇所から参照されていないことを確認済みのため。
STABILIZE_ZOOM=0
HAS_VIDSTAB=false

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
#
# 【測り方】
# 末尾フレームを少しずつずらして先頭フレームと重ね、
# 最も一致する位置を探す。そのずれ量がドリフト量になる。
# 画面を4分割してそれぞれ測ることで、
#   4つの平均      = 平行移動
#   外向きの広がり = ズーム
# を同時に取り出せる。
#
# ------------------------------------------------------------
# 【2026/08/27 の修正】測定が一度も動いていなかった問題を直した
#
# ①Pillowを使うのをやめた
#   renderジョブにはPillowが入っていない(score-loop-seamジョブにだけ
#   python3-pil を入れている)。以前の実装は `from PIL import Image` が
#   try の外にあったため import の時点で例外になり、標準出力が空のまま
#   終了していた。呼び出し側が 2>/dev/null で握りつぶしていたので、
#   awkの既定値 "0 0 1.0" が入り、毎回「ドリフトはありません」と
#   表示されていた。つまり測定が一度も走っていなかった。
#   → ffmpegに生の輝度データ(gray/rawvideo)を吐かせ、
#     標準ライブラリだけで読む。追加インストールは不要。
#
# ②判定を緩めた
#   以前は「一致度が4割以上改善しなければ動いていない」としていた。
#   夜の情景は暗く模様が乏しいため、実際にずれていても改善は1〜2割で、
#   本物のドリフトまで「動いていない」と切り捨てていた。
#   → 2%以上の改善で採用する。判断の材料は必ずログに出す。
#
# ③縮小方向のズームに対応した
#   zoompanは倍率1未満を受け付けず、1に丸める。
#   カメラが引いていく場合の倍率は0.97のような値になり、
#   以前の式は 0.97→1.00 という1以下の範囲を指定していたため、
#   フィルタとしては何もしていなかった。
#   → 補正の基準をずらし、常に1以上の範囲で指定する。
# ============================================================

# 測定に使う解像度(小さくすると速いが、細かいずれを取り逃す)
MEAS_W=960
MEAS_H=540

measure_drift_() {
  # $1 = 動画ファイル / 標準出力の最終行: "DX DY ZOOM"
  #   DX,DY = 末尾が先頭に対してずれている量(元の解像度でのpx)
  #   ZOOM  = 末尾が先頭に対して何倍になっているか(1.0なら等倍、1未満なら引いている)
  # 途中経過は標準エラーに出す(ログに残す)
  local V="$1"
  local D LAST SRCW SCALE

  D=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$V")
  SRCW=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$V")
  LAST=$(awk -v d="$D" 'BEGIN{v=d-0.1; if(v<0)v=0; printf "%.2f", v}')
  SCALE=$(awk -v a="$SRCW" -v m="$MEAS_W" 'BEGIN{printf "%.4f", (m>0)?a/m:1}')

  if ! ffmpeg -v error -ss 0 -i "$V" -frames:v 1 \
       -vf "scale=${MEAS_W}:${MEAS_H}" -pix_fmt gray -f rawvideo -y drift_a.raw 2>/dev/null; then
    echo "    測定: 先頭フレームを取り出せませんでした" >&2
    echo "0 0 1.0"; return
  fi
  if ! ffmpeg -v error -ss "$LAST" -i "$V" -frames:v 1 \
       -vf "scale=${MEAS_W}:${MEAS_H}" -pix_fmt gray -f rawvideo -y drift_b.raw 2>/dev/null; then
    echo "    測定: 末尾フレームを取り出せませんでした" >&2
    echo "0 0 1.0"; return
  fi

  MEAS_W="$MEAS_W" MEAS_H="$MEAS_H" MEAS_SCALE="$SCALE" python3 - <<'DRIFTPY'
import os, sys

W = int(os.environ['MEAS_W'])
H = int(os.environ['MEAS_H'])
SCALE = float(os.environ['MEAS_SCALE'])

def bail(msg):
    print('    測定: ' + msg, file=sys.stderr)
    print('0 0 1.0')
    raise SystemExit

try:
    a = open('drift_a.raw', 'rb').read()
    b = open('drift_b.raw', 'rb').read()
except Exception as e:
    bail('フレームを読めませんでした (%s)' % e)

if len(a) < W * H or len(b) < W * H:
    bail('データが足りません (a=%d b=%d 必要=%d)' % (len(a), len(b), W * H))

STEP = 4          # 何画素おきに比べるか(小さいほど正確だが遅い)
RANGE = 16        # 探す範囲(±px、測定解像度での値)
COARSE = 2        # 粗探しの刻み

def diff(x0, y0, rw, rh, dx, dy):
    """末尾を(dx,dy)ずらしたときの、先頭との明るさの差の平均"""
    tot = 0
    n = 0
    for y in range(y0, y0 + rh, STEP):
        ry = y + dy
        if ry < 0 or ry >= H:
            continue
        ra = y * W
        rb = ry * W
        for x in range(x0, x0 + rw, STEP):
            rx = x + dx
            if rx < 0 or rx >= W:
                continue
            d = a[ra + x] - b[rb + rx]
            tot += d if d >= 0 else -d
            n += 1
    return (tot / n) if n else 9e9

def subpixel(d_minus, d0, d_plus):
    """前後1pxの一致度から、1px未満のずれを放物線あてはめで求める

    ズームは「4隅のずれの差」から求めるため、1pxの丸め誤差が
    そのまま倍率の誤差になる。検証では3.00%のズームを3.51%と
    測ってしまい、そのぶん補正が効きすぎた。
    小数点以下まで求めれば、この測りすぎがほぼ消える。
    """
    den = d_minus - 2 * d0 + d_plus
    if den <= 1e-9:
        return 0.0
    delta = 0.5 * (d_minus - d_plus) / den
    if delta > 1.0:
        delta = 1.0
    elif delta < -1.0:
        delta = -1.0
    return delta

def measure(cx, cy, rw, rh):
    """この領域が末尾でどれだけ動いたかを測る"""
    x0 = int(cx - rw / 2)
    y0 = int(cy - rh / 2)
    base = diff(x0, y0, rw, rh, 0, 0)

    best = None
    for dy in range(-RANGE, RANGE + 1, COARSE):
        for dx in range(-RANGE, RANGE + 1, COARSE):
            s = diff(x0, y0, rw, rh, dx, dy)
            if best is None or s < best[0]:
                best = (s, dx, dy)
    bs, bdx, bdy = best

    # 粗探しで見つけた位置の周り1pxを細かく見る
    for dy in range(bdy - 1, bdy + 2):
        for dx in range(bdx - 1, bdx + 2):
            s = diff(x0, y0, rw, rh, dx, dy)
            if s < bs:
                bs, bdx, bdy = s, dx, dy

    # 1px未満のずれを求める
    fx = subpixel(diff(x0, y0, rw, rh, bdx - 1, bdy), bs,
                  diff(x0, y0, rw, rh, bdx + 1, bdy))
    fy = subpixel(diff(x0, y0, rw, rh, bdx, bdy - 1), bs,
                  diff(x0, y0, rw, rh, bdx, bdy + 1))

    return bdx + fx, bdy + fy, base, bs

# ---- 測る場所 ----
#
# 【4隅の大きな領域から、小さな格子に変えた理由】
# 領域が大きいと、その中のどこの模様が一致したかによって
# 「画面中心からどれだけ離れた場所のずれか」が変わってしまう。
# 模様が外寄りに偏っていると、実際より遠くのずれとして扱われ、
# ズーム量が大きめに出る(検証で真値2.9%を3.5%と測った)。
#
# 小さな領域をたくさん取れば、この偏りは箇所ごとにばらけるため、
# 当てはめの段階で打ち消し合う。
GRID_X = [0.16, 0.34, 0.50, 0.66, 0.84]
GRID_Y = [0.22, 0.50, 0.78]
rw = int(W * 0.16)
rh = int(H * 0.22)
pts = [(W * gx, H * gy) for gy in GRID_Y for gx in GRID_X]

# 判定のしきい値
#   MIN_TEXTURE … これ未満は模様が乏しく、どこでも一致してしまうので信用しない
#   MIN_GAIN    … 一致度がこの割合まで改善していれば「動いた」とみなす
MIN_TEXTURE = 1.2
MIN_GAIN = 0.98

res = []
rejected_flat = 0
rejected_still = 0
for cx, cy in pts:
    dx, dy, base, bs = measure(cx, cy, rw, rh)
    ratio = (bs / base) if base > 0 else 1.0
    if base < MIN_TEXTURE:
        rejected_flat += 1
        res.append(None)
    elif ratio > MIN_GAIN:
        rejected_still += 1
        res.append(None)
    else:
        res.append((dx, dy))

adopted = sum(1 for r in res if r is not None)
print('    測った%d箇所のうち %d箇所を採用(模様が乏しい %d / 動きなし %d)'
      % (len(pts), adopted, rejected_flat, rejected_still), file=sys.stderr)

# ---- 読めた領域から、平行移動とズームを同時に当てはめる ----
#
# 【なぜ平均と引き算をやめたか】
# 以前は「4つの平均=平行移動」「外向きの広がり=ズーム」としていた。
# これは4隅すべてが読めているときしか成り立たない。
# 実際の素材では、水面のように動くものが乗った領域は読めずに外れる。
# 3箇所しか読めないと、残った側に平均が引っ張られ、
# 本当はズームなのに「平行移動がある」と誤判定してしまう。
# (実素材のログで、存在しない6pxのパンを補正しようとしていた)
#
# 各領域のずれを「平行移動 + 中心から外向きの広がり」という式に
# 最小二乗で当てはめれば、3箇所でも両方を正しく分離できる。
#   dx = tx + s*(x - 中心x)
#   dy = ty + s*(y - 中心y)     s が 0 なら等倍、正なら寄り、負なら引き
U = []; V = []; DXS = []; DYS = []
for (cx, cy), r in zip(pts, res):
    if r is None:
        continue
    U.append(cx - W / 2.0)
    V.append(cy - H / 2.0)
    DXS.append(r[0])
    DYS.append(r[1])

def fit(U, V, DXS, DYS):
    n = len(U)
    Su = sum(U); Sv = sum(V)
    Sdx = sum(DXS); Sdy = sum(DYS)
    Suu = sum(u * u + v * v for u, v in zip(U, V))
    Sud = sum(u * dx + v * dy for u, v, dx, dy in zip(U, V, DXS, DYS))
    den = Suu - (Su * Su + Sv * Sv) / float(n)
    if den <= 1e-6:
        return Sdx / float(n), Sdy / float(n), 0.0
    sc = (Sud - (Su * Sdx + Sv * Sdy) / float(n)) / den
    return (Sdx - Su * sc) / float(n), (Sdy - Sv * sc) / float(n), sc

n = len(U)
if n == 0:
    print('    どの領域からも動きを読み取れませんでした', file=sys.stderr)
    print('0 0 1.0')
    raise SystemExit

zoom = 1.0
if n >= 3:
    mdx, mdy, sc = fit(U, V, DXS, DYS)

    # ---- 当てはめから大きく外れた箇所を捨てて、もう一度当てはめる ----
    #
    # 水面や湯気が乗った領域は、構造物とは別の方向に動いて見える。
    # そのまま混ぜると平行移動の値が引っ張られ、実際には無いパンを
    # 補正しようとしてしまう(実素材で存在しない6pxのパンが出た)。
    # いったん当てはめた式からの外れ具合を見て、目立って外れたものを外す。
    err = [abs(dx - (mdx + sc * u)) + abs(dy - (mdy + sc * v))
           for u, v, dx, dy in zip(U, V, DXS, DYS)]
    srt = sorted(err)
    med = srt[len(srt) // 2]
    limit = max(2.0, med * 2.5)
    keep = [i for i, e in enumerate(err) if e <= limit]
    if len(keep) >= 3 and len(keep) < n:
        print('    当てはめから外れた%d箇所を除きます(水面や湯気の可能性)'
              % (n - len(keep)), file=sys.stderr)
        U = [U[i] for i in keep]; V = [V[i] for i in keep]
        DXS = [DXS[i] for i in keep]; DYS = [DYS[i] for i in keep]
        n = len(U)
        mdx, mdy, sc = fit(U, V, DXS, DYS)

    zoom = 1.0 + sc
    print('    当てはめ(%d箇所): 平行移動 x=%+.1f y=%+.1f / 倍率%.4f'
          % (n, mdx, mdy, zoom), file=sys.stderr)
    if zoom < 0.9 or zoom > 1.1:
        print('    倍率が異常なため無視します', file=sys.stderr)
        zoom = 1.0
else:
    mdx = sum(DXS) / float(n)
    mdy = sum(DYS) / float(n)
    print('    %d箇所しか読めなかったため、平行移動だけ求めます' % n, file=sys.stderr)

print('%d %d %.4f' % (int(round(mdx * SCALE)), int(round(mdy * SCALE)), zoom))
DRIFTPY
}

# 補正の強さの候補
#
# 【なぜ測った値をそのまま使わないのか】
# ずれの測り方には、素材の模様の偏りによる誤差がどうしても残る。
# 検証では、真値2.9%のズームを条件によって2.3%とも3.5%とも測った。
# 補正フィルタ側の効き方にも同じくらいの幅がある。
# 測った値を信じて一度で決めると、足りないか行き過ぎるかのどちらかになる。
#
# そこで強さを変えた候補をいくつか作り、それぞれ「残りのずれ」を測って
# いちばん小さくなったものを採用する。
# ループ候補3本から最良を選ぶのと同じ考え方で、
# 推定の誤差そのものを避けられる。
DRIFT_STRENGTHS="0.6 0.8 1.0 1.2"

# ズーム補正の上限(%)。これを超える値は測定の誤りとみなす
DRIFT_MAX_ZOOM_PCT=4

# ずれの大きさをひとつの数字にまとめる(px + ズーム%×10)
drift_magnitude_() {
  awk -v x="$1" -v y="$2" -v z="$3" \
    'BEGIN{ax=(x<0)?-x:x; ay=(y<0)?-y:y; d=(z>1)?z-1:1-z; printf "%.1f", ax+ay+d*1000}'
}

# ドリフトを打ち消したクリップを作る
#   $1=入力 $2=出力 $3=x方向(px) $4=y方向(px) $5=倍率
#   成功したら標準出力に「拡大率(%)」を返す
apply_drift_fix_() {
  local IN="$1" OUT="$2" FDX="$3" FDY="$4" FDZ="$5"
  local CD CWID CHGT CFPS ABSX ABSY ZOOM_VF ZMAX ZSTART ZEND FRAMES
  local ZPAD ZPADY MARGIN CW CH XMAX YMAX SX SY PCT

  CD=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$IN")
  CWID=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$IN")
  CHGT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$IN")

  # 【元のフレームレートを必ず引き継ぐ】
  # LTXのクリップは25fpsで出てくることがある。
  # zoompanに fps=30 を渡すと、25枚ぶんの絵を30fpsとして貼り直すため、
  # 中身が2割速くなって尺が縮む(実素材で6.1秒→5.1秒になった)。
  # そのうえ補正の傾斜も伸びた尺で計算されるので、最後まで届かず効きが弱くなる。
  # フレームレートの変換は、あとの中間フレーム生成にまかせる。
  CFPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$IN" \
         | awk -F/ '{ if (NF==2 && $2>0) printf "%.4f", $1/$2; else printf "%.4f", $1 }')
  if [ -z "$CFPS" ] || awk -v f="$CFPS" 'BEGIN{exit !(f<1)}'; then CFPS=30; fi

  ABSX=$(awk -v v="$FDX" 'BEGIN{printf "%d", (v<0)?-v:v}')
  ABSY=$(awk -v v="$FDY" 'BEGIN{printf "%d", (v<0)?-v:v}')

  # 【ズーム補正の倍率】
  #
  # 末尾は先頭に対して FDZ 倍になっている。これを打ち消すには
  # 時間とともに 1/FDZ 倍していけばよい。
  # ただしzoompanは1未満の倍率を受け付けず1に丸めるため、
  # 全体を持ち上げて常に1以上になるようにする。
  #
  #   ZSTART = max(1, FDZ)      ZEND = ZSTART / FDZ
  #   FDZ<1(引いていく) … 1.0000 → 1/FDZ    FDZ>1(寄っていく) … FDZ → 1.0000
  #
  # 以前は常に FDZ → 1 としていたため、引いていく場合に1以下の範囲を
  # 指定してしまい、フィルタが何もしていなかった。
  # 「少しずつ引いていって周期の頭で戻る」症状が消えなかったのはこれが原因。
  ZOOM_VF=""
  ZMAX=1
  if awk -v z="$FDZ" 'BEGIN{d=(z>1)?z-1:1-z; exit !(d>0.001)}'; then
    FRAMES=$(awk -v d="$CD" -v f="$CFPS" 'BEGIN{printf "%d", d*f}')
    ZSTART=$(awk -v z="$FDZ" 'BEGIN{printf "%.6f", (z>1)?z:1}')
    ZEND=$(awk -v z="$FDZ" 'BEGIN{s=(z>1)?z:1; printf "%.6f", s/z}')
    ZMAX=$(awk -v a="$ZSTART" -v b="$ZEND" 'BEGIN{printf "%.6f", (a>b)?a:b}')
    ZOOM_VF="zoompan=z='${ZSTART}+(${ZEND}-${ZSTART})*in/${FRAMES}':d=1:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=${CWID}x${CHGT}:fps=${CFPS}"
  fi

  # 平行移動ぶんに加えて、ズーム補正で内側に寄るぶんの余白も確保する
  ZPAD=$(awk -v zm="$ZMAX" -v w="$CWID" 'BEGIN{printf "%d", w*(zm-1)/2}')
  ZPADY=$(awk -v zm="$ZMAX" -v h="$CHGT" 'BEGIN{printf "%d", h*(zm-1)/2}')
  MARGIN=6
  CW=$(( (CWID - ABSX - ZPAD*2 - MARGIN*2) / 2 * 2 ))
  CH=$(( (CHGT - ABSY - ZPADY*2 - MARGIN*2) / 2 * 2 ))
  if [ "$CW" -lt 320 ] || [ "$CH" -lt 180 ]; then return 1; fi
  XMAX=$(( CWID - CW )); YMAX=$(( CHGT - CH ))

  # 動く方向を考え、枠内に収まる位置から始める
  if [ "$FDX" -lt 0 ]; then SX=$XMAX; else SX=0; fi
  if [ "$FDY" -lt 0 ]; then SY=$YMAX; else SY=0; fi

  PCT=$(awk -v w="$CWID" -v cw="$CW" 'BEGIN{printf "%.1f", (w/cw-1)*100}')

  # 【いったん拡大してから補正する理由】
  #
  # crop も zoompan も、切り出す位置と大きさを整数の画素に丸める。
  # 6秒かけて3%ズームさせると、丸めのせいで画面全体が1px単位で階段状に飛ぶ。
  # 動かないコマと大きく飛ぶコマが交互に来るため、これが「かくかく」になる。
  #
  # 実測(静止画に3%ズームをかけ、コマ間の変化のばらつきを測ったもの):
  #   素材そのもの      0.026
  #   そのまま補正      0.217  ← 8倍に悪化。これがカクつきの正体だった
  #   6倍にしてから補正 0.058
  #
  # 先に6倍へ引き伸ばしておけば、丸めの単位が元の1/6画素になり、
  # 段差が知覚できない大きさまで下がる。最後に元の大きさへ戻す。
  # 6倍でも中間の絵は一時的なもので、メモリは0.3GB程度、6秒のクリップで14秒ほど。
  local SS=${DRIFT_SUPERSAMPLE:-6}
  local CHAIN="scale=iw*${SS}:ih*${SS}:flags=neighbor,"
  CHAIN="${CHAIN}crop=$((CW*SS)):$((CH*SS)):x='clip((${SX}+(${FDX})*t/${CD})*${SS},0,${XMAX}*${SS})':y='clip((${SY}+(${FDY})*t/${CD})*${SS},0,${YMAX}*${SS})'"
  if [ -n "$ZOOM_VF" ]; then
    # zoompanが拡大の打ち消しと、元の大きさへの縮小をまとめて行う
    CHAIN="${CHAIN},${ZOOM_VF}"
  else
    CHAIN="${CHAIN},scale=${CWID}:${CHGT}"
  fi

  if ffmpeg -y -i "$IN" -vf "$CHAIN" \
       -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -r "$CFPS" -an "$OUT" 2>"err_driftfix.log"; then
    echo "$PCT"
    return 0
  fi
  return 1
}

DRIFT_ZOOM_PCT=""
if [ "${DRIFT_CORRECTION_ENABLED:-1}" = "1" ]; then
  echo "ループクリップのドリフトを測って打ち消します..."
  for ((i=0; i<CLIP_COUNT; i++)); do
    echo "  クリップ$((i+1)) を測ります..."
    DRIFT=$(measure_drift_ "stage_clip_raw_$i.mp4" | tail -1)
    DX=$(echo "$DRIFT" | awk '{print ($1=="")?0:$1}')
    DY=$(echo "$DRIFT" | awk '{print ($2=="")?0:$2}')
    DZ=$(echo "$DRIFT" | awk '{print ($3=="")?1.0:$3}')

    # 測りすぎの歯止め
    DZ=$(awk -v z="$DZ" -v m="$DRIFT_MAX_ZOOM_PCT" 'BEGIN{u=1+m/100; l=1-m/100; if(z>u)z=u; if(z<l)z=l; printf "%.4f", z}')

    ZPCT=$(awk -v z="$DZ" 'BEGIN{printf "%+.2f", (z-1)*100}')
    HAS_ZOOM=$(awk -v z="$DZ" 'BEGIN{d=(z>1)?z-1:1-z; print (d>0.003)?1:0}')
    HAS_PAN=$(awk -v x="$DX" -v y="$DY" 'BEGIN{ax=(x<0)?-x:x; ay=(y<0)?-y:y; print (ax>=2||ay>=2)?1:0}')
    MAG0=$(drift_magnitude_ "$DX" "$DY" "$DZ")

    if [ "$HAS_PAN" = "0" ] && [ "$HAS_ZOOM" = "0" ]; then
      echo "  クリップ$((i+1)): 補正不要 (x=${DX}px y=${DY}px ズーム${ZPCT}%)"
      continue
    fi

    echo "  クリップ$((i+1)): ドリフト x=${DX}px y=${DY}px ズーム${ZPCT}% (ずれの大きさ ${MAG0})"
    echo "  強さを変えて試し、残りがいちばん小さいものを選びます"

    BEST_MAG="$MAG0"
    BEST_PCT=""
    BEST_LABEL=""
    rm -f "drift_best_$i.mp4"

    for K in $DRIFT_STRENGTHS; do
      KDX=$(awk -v v="$DX" -v k="$K" 'BEGIN{printf "%d", (v*k<0)? int(v*k-0.5) : int(v*k+0.5)}')
      KDY=$(awk -v v="$DY" -v k="$K" 'BEGIN{printf "%d", (v*k<0)? int(v*k-0.5) : int(v*k+0.5)}')
      KDZ=$(awk -v z="$DZ" -v k="$K" 'BEGIN{printf "%.4f", 1+(z-1)*k}')

      PCT=$(apply_drift_fix_ "stage_clip_raw_$i.mp4" "cand_drift_$i.mp4" "$KDX" "$KDY" "$KDZ") || {
        echo "    強さ${K}倍: 作成に失敗しました"
        tail -3 err_driftfix.log 2>/dev/null || true
        continue
      }

      # 候補の残りを測る(途中経過は出さず、結果だけ見る)
      CAND=$(measure_drift_ "cand_drift_$i.mp4" 2>/dev/null | tail -1)
      CDX=$(echo "$CAND" | awk '{print ($1=="")?0:$1}')
      CDY=$(echo "$CAND" | awk '{print ($2=="")?0:$2}')
      CDZ=$(echo "$CAND" | awk '{print ($3=="")?1.0:$3}')
      CMAG=$(drift_magnitude_ "$CDX" "$CDY" "$CDZ")
      CZPCT=$(awk -v z="$CDZ" 'BEGIN{printf "%+.2f", (z-1)*100}')

      MARK=""
      if awk -v a="$CMAG" -v b="$BEST_MAG" 'BEGIN{exit !(a < b)}'; then
        cp "cand_drift_$i.mp4" "drift_best_$i.mp4"
        BEST_MAG="$CMAG"
        BEST_PCT="$PCT"
        BEST_LABEL="$K"
        MARK=" ←現時点で最良"
      fi
      echo "    強さ${K}倍(拡大${PCT}%): 残り x=${CDX}px y=${CDY}px ズーム${CZPCT}% → ずれの大きさ ${CMAG}${MARK}"
    done

    rm -f "cand_drift_$i.mp4"

    if [ -f "drift_best_$i.mp4" ]; then
      mv "drift_best_$i.mp4" "stage_clip_raw_$i.mp4"
      DRIFT_ZOOM_PCT="$BEST_PCT"
      echo "  クリップ$((i+1)): 強さ${BEST_LABEL}倍を採用しました(ずれの大きさ ${MAG0} → ${BEST_MAG} / 拡大${BEST_PCT}%)"
    else
      echo "  クリップ$((i+1)): どの強さでも改善しなかったため、補正せずそのまま使います"
    fi
  done
fi

echo "ループクリップの再生速度を${LOOP_SPEED}倍に落とします(雲の流れを導入部に合わせるため)..."
echo "  中間フレームの作り方: ${LOOP_SLOWDOWN_MODE}"
for ((i=0; i<CLIP_COUNT; i++)); do
  case "$LOOP_SLOWDOWN_MODE" in
    mci)
      SLOW_VF="setpts=PTS/${LOOP_SPEED},minterpolate=fps=30:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1"
      ;;
    blend)
      SLOW_VF="setpts=PTS/${LOOP_SPEED},minterpolate=fps=30:mi_mode=blend"
      ;;
    *)
      SLOW_VF="setpts=PTS/${LOOP_SPEED},fps=30"
      ;;
  esac

  if ffmpeg -y -i "stage_clip_raw_$i.mp4" \
       -vf "$SLOW_VF" -an \
       -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p "stage_clip_$i.mp4" 2>"err_speed_$i.log"; then
    RAW_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "stage_clip_raw_$i.mp4")
    NEW_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "stage_clip_$i.mp4")
    echo "  クリップ$((i+1)): ${RAW_DUR}秒 → ${NEW_DUR}秒"
  elif [ "$LOOP_SLOWDOWN_MODE" != "dup" ] && ffmpeg -y -i "stage_clip_raw_$i.mp4" \
       -vf "setpts=PTS/${LOOP_SPEED},fps=30" -an \
       -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p "stage_clip_$i.mp4" 2>"err_speed2_$i.log"; then
    echo "  クリップ$((i+1)): 中間フレームの生成に失敗したため、複製で埋める方式で作りました"
    tail -3 "err_speed_$i.log" || true
  else
    cp "stage_clip_raw_$i.mp4" "stage_clip_$i.mp4"
    echo "  クリップ$((i+1)): 速度変更に失敗したため、そのまま使います"
    tail -3 "err_speed_$i.log" || true
  fi

  # 【確認】隣り合うフレームがどれだけ同じかを数える
  # 複製で埋める方式だと6割が同一フレームになり、それがカクつきの正体だった。
  # 中間フレームが作れていれば、ここはほぼ0%になる。
  DUP=$(ffmpeg -v error -i "stage_clip_$i.mp4" -vf "scale=160:90" -pix_fmt gray -f rawvideo - 2>/dev/null | \
    python3 -c "
import sys
d=sys.stdin.buffer.read(); n=160*90
f=[d[i*n:(i+1)*n] for i in range(len(d)//n)]
s=sum(1 for i in range(1,len(f)) if f[i]==f[i-1])
print('%d%%' % (s*100//max(1,len(f)-1)))
" 2>/dev/null || echo "不明")
  echo "  クリップ$((i+1)): 直前とまったく同じフレームの割合 ${DUP}(高いほどカクつきます)"
done

# ループの継ぎ目の差を測る
#
# ループは末尾から先頭へ戻るので、その2枚がどれだけ違うかが
# そのまま「繰り返しに気づかれやすさ」になる。
# 0に近いほど気づかれにくい。20を超えると分かりやすい。
seam_score_() {
  local V="$1" D LAST
  D=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$V" 2>/dev/null)
  [ -z "$D" ] && { echo "不明"; return; }
  LAST=$(awk -v d="$D" 'BEGIN{v=d-0.05; if(v<0)v=0; printf "%.2f", v}')
  ffmpeg -v error -ss 0 -i "$V" -frames:v 1 -vf "scale=320:180" -pix_fmt gray -f rawvideo -y seam_a.raw 2>/dev/null || { echo "不明"; return; }
  ffmpeg -v error -ss "$LAST" -i "$V" -frames:v 1 -vf "scale=320:180" -pix_fmt gray -f rawvideo -y seam_b.raw 2>/dev/null || { echo "不明"; return; }
  python3 -c "
try:
    a=open('seam_a.raw','rb').read(); b=open('seam_b.raw','rb').read()
    n=min(len(a),len(b))
    idx=range(0,n,3)
    print('%.1f' % (sum(abs(a[i]-b[i]) for i in idx)/len(list(idx))))
except Exception:
    print('不明')
" 2>/dev/null || echo "不明"
}

#
# クリップをそのまま繰り返すと、最後のフレームから最初のフレームへ
# 一瞬で切り替わる。位置が合っていても、6秒後の湯気や水面の形は
# 0秒時点とまったく違うため、そこで「戻った」と分かってしまう。
#
# 末尾と先頭を重ねて溶かし合わせれば、その差が時間をかけて移り変わり、
# 切り替わりの瞬間が存在しなくなる。
#
# 【0秒にしていた経緯と、今回2秒に戻した理由】
# 以前は重ねると建物の柱や庇が二重に見えた。しかしそれは
# カメラのドリフトで2枚の位置がずれていたためで、重ねること自体が
# 原因ではなかった。ドリフトを打ち消した今は2枚の位置が揃っているので、
# 重なっても静止した構造物はぴたりと一致し、
# 動いている湯気や水面だけが溶け合う。これがまさに狙いどおりの状態。
#
#   0秒 … 重ねない。位置は合うが、湯気の形が飛ぶので戻りが分かる
#   2秒 … 動いているものだけが溶ける(現在)
#   4秒 … さらに滑らかになるが、ループ周期がその分短くなる
#
# ※重ねた秒数だけループ周期は短くなる(15.3秒 − この値)
XFADE_LOOP=2

# ---- ①-2c 空を止める ----
#
# 【なぜ止めるのか】
# 雲を落ち着かせるために全体を遅くすると、湯まで遅くなって
# 「流れている」ではなく「垂れている」ように見えてしまう。
# 空だけを別の速度で流すことはできない(空だけ末尾と先頭がつながらなくなる)。
#
# しかし星空も雲海も、そもそも動く必要がない。止めてしまえば、
# 遅くする理由がなくなり、湯は自然な速さのままにできる。
# 止まった空はループも完璧に成立する。
#
# 【なぜ境目が見えないのか】
# 貼り付けるのはクリップ自身の1コマ目。ドリフトを打ち消してあるので、
# 建物・岩・稜線といった動かないものは、映像側と完全に同じ位置にある。
# したがってマスクが構造物を横切っても、そこに差は生じない。
# 差が出るのは動いているものだけ、つまり雲だけになる。
#
# 【湯気について】
# 立ちのぼる湯気が空の領域まで届くと、そこで止まって見える。
# 境目を柔らかくぼかしてあるので、上にいくほど薄れて消えるように見える。
# 不自然なら SKY_FREEZE_HEIGHT を下げて、空の領域を狭くする。
#
#   0 … 止めない(従来どおり)
#   1 … 止める(現在)
SKY_FREEZE_ENABLED=1

# 完全に止める高さ(画面上端からの割合 %)
SKY_FREEZE_HEIGHT=32

# その下の、徐々に映像へ戻していく帯の幅(%)
SKY_FREEZE_FEATHER=14

if [ "${SKY_FREEZE_ENABLED:-0}" = "1" ]; then
  echo "空を止めます(上から${SKY_FREEZE_HEIGHT}%を固定し、続く${SKY_FREEZE_FEATHER}%で映像に戻します)..."
  for ((i=0; i<CLIP_COUNT; i++)); do
    SW=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "stage_clip_$i.mp4")
    SH=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "stage_clip_$i.mp4")
    SY1=$(awk -v h="$SH" -v p="$SKY_FREEZE_HEIGHT" 'BEGIN{printf "%d", h*p/100}')
    SFE=$(awk -v h="$SH" -v p="$SKY_FREEZE_FEATHER" 'BEGIN{printf "%d", h*p/100; }')
    [ "$SFE" -lt 1 ] && SFE=1

    # 1コマ目を取り出す(これが止まった空になる)
    if ! ffmpeg -v error -y -ss 0 -i "stage_clip_$i.mp4" -frames:v 1 "sky_still_$i.png" 2>"err_sky_$i.log"; then
      echo "  クリップ$((i+1)): 1コマ目を取り出せなかったため、空はそのままにします"
      continue
    fi

    # 上が白(静止画を見せる)、下が黒(映像を見せる)のマスクを作る
    if ! ffmpeg -v error -y -f lavfi -i "color=c=black:s=${SW}x${SH}" \
         -vf "geq=lum='if(lt(Y,${SY1}),255,if(lt(Y,${SY1}+${SFE}),255*(1-(Y-${SY1})/${SFE}),0))'" \
         -frames:v 1 "sky_mask_$i.png" 2>>"err_sky_$i.log"; then
      echo "  クリップ$((i+1)): マスクを作れなかったため、空はそのままにします"
      continue
    fi

    # 【尺を明示する】
    # 静止画は -loop 1 で無限に供給されるため、尺を指定しないと
    # 合成が永久に終わらない(実際に固まった)。
    SKY_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "stage_clip_$i.mp4")
    SKY_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "stage_clip_$i.mp4" \
              | awk -F/ '{ if (NF==2 && $2>0) printf "%.4f", $1/$2; else printf "%.4f", $1 }')
    if [ -z "$SKY_FPS" ] || awk -v f="$SKY_FPS" 'BEGIN{exit !(f<1)}'; then SKY_FPS=30; fi

    if ffmpeg -v error -y -i "stage_clip_$i.mp4" -loop 1 -i "sky_still_$i.png" -loop 1 -i "sky_mask_$i.png" \
         -filter_complex "[1:v]format=rgba[st];[2:v]format=gray[m];[st][m]alphamerge[sa];[0:v]format=rgba[bs];[bs][sa]overlay=format=rgb,format=yuv420p[out]" \
         -map "[out]" -t "$SKY_DUR" -r "$SKY_FPS" \
         -c:v libx264 -preset veryfast -crf 23 -an "stage_sky_$i.mp4" 2>>"err_sky_$i.log"; then
      mv "stage_sky_$i.mp4" "stage_clip_$i.mp4"
      echo "  クリップ$((i+1)): 空を止めました(上${SY1}px を固定、続く${SFE}px でぼかし)"
    else
      echo "  クリップ$((i+1)): 空の固定に失敗したため、そのまま使います"
      tail -5 "err_sky_$i.log" 2>/dev/null || true
    fi
  done
fi

# ---- ①-2d 止めた空に星の瞬きを描く ----
#
# 空を静止画で止めると、当然ながら星も完全に動かなくなる。
# 夜空は瞬いているほうが生きて見えるので、光る点を重ねて補う。
#
# 【できること・できないこと】
# 止めた空は写真なので、そこに写っている星そのものを光らせることはできない。
# 別の点を上から重ねる形になる。2pxの点なので夜空では見分けがつかないが、
# 元の星とは違う位置に現れる。
#
# 【周期はループ周期の約数にする】
# ループ周期を割り切らない周期で瞬かせると、繰り返しの継ぎ目で
# 明滅が不連続に飛んでしまう。1周期のあいだに2〜6回瞬く形にして、
# 必ず割り切れるようにしている。
#
#   0 … 描かない
#   1 … 描く(現在)
SKY_TWINKLE_ENABLED=1

# 描く星の数。多すぎると空が騒がしくなる
SKY_TWINKLE_COUNT=40

if [ "${SKY_TWINKLE_ENABLED:-0}" = "1" ] && [ "${SKY_FREEZE_ENABLED:-0}" = "1" ]; then
  echo "止めた空に星の瞬きを描きます(${SKY_TWINKLE_COUNT}個)..."
  for ((i=0; i<CLIP_COUNT; i++)); do
    TW_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "stage_clip_$i.mp4")
    TW_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "stage_clip_$i.mp4")
    TW_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "stage_clip_$i.mp4")
    TW_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "stage_clip_$i.mp4" \
             | awk -F/ '{ if (NF==2 && $2>0) printf "%.4f", $1/$2; else printf "%.4f", $1 }')
    if [ -z "$TW_FPS" ] || awk -v f="$TW_FPS" 'BEGIN{exit !(f<1)}'; then TW_FPS=30; fi

    # 実際に繰り返される長さ(重ねる秒数を引いたもの)を周期の基準にする
    TW_PERIOD=$(awk -v d="$TW_DUR" -v x="$XFADE_LOOP" 'BEGIN{v=d-x; if(v<1)v=d; printf "%.4f", v}')

    # 星を置ける高さ(完全に止まっている範囲のみ。ぼかしの帯には置かない)
    TW_TOP=$(awk -v h="$TW_H" -v p="$SKY_FREEZE_HEIGHT" 'BEGIN{printf "%d", h*p/100}')

    TW_BOXES=""
    for ((k=1; k<=SKY_TWINKLE_COUNT; k++)); do
      eval "$(awk -v i=$k -v w="$TW_W" -v top="$TW_TOP" -v P="$TW_PERIOD" 'BEGIN{
        srand(i*7919);
        x=int(rand()*w);
        y=int(rand()*top*0.95);
        n=int(2+rand()*5);        # 1周期に2〜6回瞬く(必ず割り切れる)
        p=P/n;
        ph=rand()*6.28;           # 位相をばらす
        th=0.30+rand()*0.40;      # 点いている時間の割合もばらす
        g=int(170+rand()*85);     # 明るさもばらす(色は16進で渡す必要がある)
        printf "TX=%d; TY=%d; TP=%.4f; TPH=%.2f; TTH=%.2f; TG=%02X", x, y, p, ph, th, g
      }')"
      TW_BOXES="${TW_BOXES}drawbox=x=${TX}:y=${TY}:w=2:h=2:color=0x${TG}${TG}${TG}:t=fill:enable='gt(sin(2*PI*t/${TP}+${TPH}),${TTH})',"
    done

    if ffmpeg -v error -y -i "stage_clip_$i.mp4" \
         -f lavfi -i "color=c=black:s=${TW_W}x${TW_H}:d=${TW_DUR}:r=${TW_FPS}" \
         -filter_complex "[1:v]${TW_BOXES%,},gblur=sigma=1.1,format=gbrp[tw];[0:v]format=gbrp[bs];[bs][tw]blend=all_mode=screen,format=yuv420p[out]" \
         -map "[out]" -t "$TW_DUR" -r "$TW_FPS" \
         -c:v libx264 -preset veryfast -crf 23 -an "stage_tw_$i.mp4" 2>"err_twinkle_$i.log"; then
      mv "stage_tw_$i.mp4" "stage_clip_$i.mp4"
      echo "  クリップ$((i+1)): 星の瞬きを描きました(上${TW_TOP}px の範囲 / 周期の基準 ${TW_PERIOD}秒)"
    else
      echo "  クリップ$((i+1)): 星の瞬きを描けなかったため、そのまま使います"
      tail -5 "err_twinkle_$i.log" 2>/dev/null || true
    fi
  done
fi

# ---- ①-3 クリップをシームレスループに加工する ----


# 導入部とループの境目を溶かす秒数
#
# ループの継ぎ目(XFADE_LOOP)とは別に設定する。
# 導入部の終盤はカメラが停止しているため、長く溶かすと二重像が
# 動かないまま居座り、「残像」として見えてしまう。
# 1秒だと変化が急で境目が見えたため2秒にしている。
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
  SEAM_BEFORE=$(seam_score_ "stage_clip_$i.mp4")

  if awk "BEGIN{exit !($XFADE_LOOP < 0.01)}"; then
    cp "stage_clip_$i.mp4" "stage_loop_$i.mp4"
    LOOP_DUR="$CLIP_DUR"
    SEAMLESS_DUR="$LOOP_DUR"
    LOOP_HEAD_FILE=""
    echo "  クリップ$((i+1)): 重ねずにそのまま繋ぎます(${CLIP_DUR}秒 / 継ぎ目の差 ${SEAM_BEFORE})"
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
    SEAM_AFTER=$(seam_score_ "stage_loop_$i.mp4")
    echo "  クリップ$((i+1)): ${XFADE_LOOP}秒かけて溶かしました(${CLIP_DUR}秒 → ${LOOP_DUR}秒)"
    echo "  クリップ$((i+1)): 継ぎ目の差 ${SEAM_BEFORE} → ${SEAM_AFTER}(小さいほど戻りに気づかれにくい)"
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
# ドリフト補正でループ側が拡大されるため、導入部にも同じ倍率をかけて
# 切り替わる瞬間に画の大きさが変わらないようにする。
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
    # 補正の拡大がループ側にだけ掛かると、切り替わる瞬間に画が一回り大きくなる。
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

# ---- 静止画ベースのループを作る(手描きのループ動画と同じ発想) ----
#
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

  # 合成の実行
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

    # 星の明滅を組み立てる(空の領域に小さな点を散らし、周期をずらして瞬かせる)
    STAR_BOXES=""
    SKY=$(echo "$LAYER_REGIONS" | jq -r '.sky // empty | "\(.x) \(.y) \(.w) \(.h)"' 2>/dev/null)
    if [ -n "$SKY" ]; then
      read SX SY SW SH <<< "$SKY"
      STAR_COUNT=28
      for ((s=1; s<=STAR_COUNT; s++)); do
        eval "$(awk -v i=$s -v sx=$SX -v sy=$SY -v sw=$SW -v sh=$SH -v P=$UNIT_DUR 'BEGIN{
          srand(i*7919);
          x=int(1920*(sx+rand()*sw)/100);
          y=int(1080*(sy+rand()*sh*0.85)/100);
          n=int(2+rand()*5);
          p=P/n;
          ph=rand()*6.28;
          th=0.35+rand()*0.35;
          printf "STX=%d; STY=%d; STP=%.4f; STPH=%.2f; STTH=%.2f", x, y, p, ph, th
        }')"
        STAR_BOXES="${STAR_BOXES}drawbox=x=${STX}:y=${STY}:w=2:h=2:color=white:t=fill:enable='gt(sin(2*PI*t/${STP}+${STPH}),${STTH})',"
      done
      echo "  星の明滅: ${STAR_COUNT}個を空の領域に配置"
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
  case "$PARTICLE_KEY" in
    onsen)
      # 湯の音: BGMは低域を残し、水の弾ける帯域(2〜5kHz)だけ軽く譲る
      BGM_EQ="equalizer=f=3000:width_type=o:width=1.5:g=-2,aecho=0.8:0.9:50:0.2"
      # 環境音: 低域を削ってBGMの土台を邪魔しない
      #   loudnorm で音圧を一定に揃えてから音量を決める。
      #   aecho の遅延を長め(120ms)にして、岩に囲まれた露天風呂の広がりを出す
      AMBIENT_EQ_BASE="highpass=f=80,loudnorm=I=-20:TP=-2,aecho=0.8:0.88:120:0.35"
      AMBIENT_LOWPASS=8000
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
  # 曲そのものは変わっていないのに、戸を開けた瞬間に楽器が増えたように聴こえる。
  # 「同じ音楽が空間ごと広がる」体験になり、繋ぎ目が生まれない。
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
  # 遠い音は「小さい」だけでなく「高域が減衰してこもって聴こえる」。
  # 空気や壁が高い周波数から先に吸収するためで、音量だけを絞っても
  # 「近くで小さく鳴っている音」にしか聴こえない。
  #
  # 効果音は完全な無音から始める。
  # 導入部の開始位置は建物のいちばん奥で、露天風呂からかなり離れている。
  # そこで湯の音が聞こえるのは物理的におかしいため、
  # 戸に近づくにつれて初めて聞こえ始める形にする。
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
