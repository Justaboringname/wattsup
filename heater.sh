#!/bin/zsh
# heatwire —— 把 CPU / 内存 / GPU(硬件光追、Metal 4 张量) / ANE 同时拉满，边烤边记功耗和温度。
#
#   ./heater.sh [预设] [秒数]          预设默认 peak，秒数默认 60
#
# 预设(各单元的参数，见下表)：
#   peak    CPU + 内存 + 光追 + ANE(不跑张量)  —— 实测整机峰值 326 W 的配置
#   mix     CPU + 内存 + 光追 + 张量 + ANE      —— 所有单元都有活干，峰值约 305 W
#   cpu / mem / gpu / rt / tensor / ane          —— 单烤某一块
# 任何一项都能用环境变量覆盖：SF_T SF_NICE MEM_T MEM_NICE RT_TRIS NA ANE_T，例如
#   RT_TRIS=10000 ./heater.sh peak 30
#
# 每次运行的日志放在 runs/<时间>-<预设>/ 下，跑完打印汇总。
set -u
cd "$(dirname "$0")"
PRESET=${1:-peak}; T=${2:-60}
#            SF_T SF_NICE MEM_T MEM_NICE RT_TRIS NA ANE_T
case $PRESET in
  peak)   d=(18   20      4     20       5000    0  8) ;;
  mix)    d=(18   20      4     20       5000    1  8) ;;
  cpu)    d=(18   0       0     0        0       0  0) ;;
  mem)    d=(0    0       4     0        0       0  0) ;;
  gpu)    d=(0    0       0     0        5000    1  0) ;;
  rt)     d=(0    0       0     0        5000    0  0) ;;
  tensor) d=(0    0       0     0        0       1  0) ;;
  ane)    d=(0    0       0     0        0       0  8) ;;
  *) echo "未知预设：$PRESET（可选 peak mix cpu mem gpu rt tensor ane）"; exit 1 ;;
esac
: ${SF_T:=$d[1]} ${SF_NICE:=$d[2]} ${MEM_T:=$d[3]} ${MEM_NICE:=$d[4]} ${RT_TRIS:=$d[5]} ${NA:=$d[6]} ${ANE_T:=$d[7]}

for tool in fanctl macmon; do
  command -v $tool >/dev/null || { echo "缺少 $tool（见 README 的依赖一节）"; exit 1; }
done
[ $SF_T -gt 0 ] && ! command -v stockfish >/dev/null && { echo "缺少 stockfish：brew install stockfish"; exit 1; }
[ -x bin/rt_stress ] || { echo "先 make"; exit 1; }

RUN=runs/$(date +%Y%m%d-%H%M%S)-$PRESET
mkdir -p $RUN
echo idle > $RUN/phase
python3 -u log/thermlog.py $RUN/slow.csv 3 $RUN/phase 2> $RUN/thermlog.err &
L1=$!
python3 -u log/pstrfast.py $RUN/fast.csv $RUN/phase 2> /dev/null &
L2=$!
trap 'kill $L1 $L2 ${P[@]:-} 2>/dev/null' EXIT INT TERM
P=()
echo "$PRESET: SF_T=$SF_T SF_NICE=$SF_NICE MEM_T=$MEM_T MEM_NICE=$MEM_NICE RT_TRIS=$RT_TRIS NA=$NA ANE_T=$ANE_T，${T} 秒 → $RUN"
sleep 5

echo load > $RUN/phase
P=()
if [ $SF_T -gt 0 ];    then nice -n $SF_NICE stockfish speedtest $SF_T 2048 $T > $RUN/cpu.log 2>&1 & P+=($!); fi
if [ $MEM_T -gt 0 ];   then nice -n $MEM_NICE bin/membw $T $MEM_T > $RUN/mem.log 2>&1 & P+=($!); fi
if [ $RT_TRIS -gt 0 ]; then bin/rt_stress $T $RT_TRIS 2048 32 > $RUN/rt.log 2>&1 & P+=($!); fi
if [ $NA -gt 0 ];      then bin/na_stress $T 1024 256 half > $RUN/tensor.log 2>&1 & P+=($!); fi
if [ $ANE_T -gt 0 ];   then bin/ane_stress $T $ANE_T 1024 pose > $RUN/ane.log 2>&1 & P+=($!); fi
for p in $P; do wait $p; done

echo cool > $RUN/phase
sleep 15
kill $L1 $L2 2>/dev/null
trap - EXIT INT TERM
python3 log/summary.py $RUN
