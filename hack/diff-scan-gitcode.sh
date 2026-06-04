#!/usr/bin/env bash
# diff-scan-gitcode.sh OWNER/REPO TASK [PATHPREFIX...]
#
# ai-radar diff-watch 的 GitCode 取数器 —— 用 api.gitcode.com/api/v5 的 compare 端点
# (Gitee 风格,匿名可用,files[].patch 直接带真实 diff hunk),**不需要 clone**。
# PATHPREFIX 留空=全仓;给了则只保留 filename 以任一 prefix 开头的文件(用于 mind-cluster 按 component/ 限定)。
# 锚点 repo 名 = OWNER/REPO 的 basename,与历史 digest 锚点一致。脚本只读。
set -uo pipefail
REPO="${1:?usage: diff-scan-gitcode.sh OWNER/REPO TASK [PATHPREFIX...]}"
TASK="${2:?task name required}"
shift 2
PREFIXES=("$@")
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
API=https://api.gitcode.com/api/v5
HDR=(); [ -n "${GITCODE_TOKEN:-}" ] && HDR=(-H "PRIVATE-TOKEN: $GITCODE_TOKEN")  # 被限流时 .env 配 GITCODE_TOKEN
gc(){ curl -s -m25 "${HDR[@]}" "$API/repos/$REPO/$1"; }

NAME="${REPO##*/}"
TODAY=$(date +%Y-%m-%d)
HEAD_SHA=$(gc "commits?per_page=1" | jq -r '.[0].sha // empty')
[ -z "$HEAD_SHA" ] && { echo "### $NAME"; echo "FETCH FAILED ($REPO,检查 owner/repo 或 GitCode API)"; exit 0; }
LATEST_TAG=$(gc "tags" | jq -r 'if type=="array" then (sort_by(.commit.date // .commit.committed_date // "") | reverse | .[0].name // "—") else "—" end' 2>/dev/null)

# base:优先上一篇 digest 锚点;否则取 ~3 天前的提交
PREV=$(ls -1 "$ROOT"/digests/*-"$TASK".md 2>/dev/null | grep -v "/$TODAY-" | sort | tail -1)
BASE=""; WINDOW=""
FIRSTRUN=0
[ -n "$PREV" ] && BASE=$(grep -oE "ANCHOR repo=$NAME sha=[0-9a-f]+" "$PREV" 2>/dev/null | head -1 | sed 's/.*sha=//')
# 首跑:只建立锚点 base=HEAD,不补历史 diff;从第 2 次起做小增量。
[ -z "$BASE" ] && { BASE="$HEAD_SHA"; FIRSTRUN=1; }

echo "### $NAME"
echo "<!-- ANCHOR repo=$NAME sha=$HEAD_SHA tag=$LATEST_TAG scanned=$TODAY -->"
if [ -z "$BASE" ] || [ "$BASE" = "$HEAD_SHA" ]; then
  if [ "$FIRSTRUN" = 1 ]; then
    echo "- 首跑: 仅建立锚点 sha=${HEAD_SHA:0:8},从下次起跟踪增量 | tag: $LATEST_TAG"
    echo "__BASELINE__"
  else
    echo "- 比较: ${BASE:0:8}..${HEAD_SHA:0:8} | tag: $LATEST_TAG | 无新提交"
    echo "__EMPTY__"
  fi
  exit 0
fi

CMP=$(gc "compare/$BASE...$HEAD_SHA")
TRUNC=$(echo "$CMP" | jq -r '.truncated // false')

# 路径前缀过滤(client-side):把 PREFIXES 拼成 jq 正则
PFILTER='true'
if [ "${#PREFIXES[@]}" -gt 0 ]; then
  RE=$(printf '%s|' "${PREFIXES[@]}"); RE="^(${RE%|})"
  PFILTER="(.filename|test(\"$RE\"))"
fi

SUBJECTS=$(echo "$CMP" | jq -r '.commits[]?.commit.message | split("\n")[0]' \
  | grep -viE '^(Merge|!?[0-9]+ *merge|[Bb]ump|\[ci|chore|cleancode|format|update version)')
if [ -z "$SUBJECTS" ]; then
  echo "- 比较: ${BASE:0:8}..${HEAD_SHA:0:8} $WINDOW | tag: $LATEST_TAG | 仅 merge/bump/CI"
  echo "__EMPTY__"; exit 0
fi

NCMT=$(echo "$CMP" | jq -r '.commits|length')
echo "- 比较: ${BASE}..${HEAD_SHA:0:8} $WINDOW | tag: $LATEST_TAG | commits=$NCMT | truncated=$TRUNC"

# 自适应:大区间(首跑常见)或被截断 → 概览模式,不逐文件读 hunk
if [ "$TRUNC" = "true" ] || { [ "$NCMT" -gt 60 ] 2>/dev/null; }; then
  echo "__OVERVIEW__ 首跑/大区间(commits=$NCMT,truncated=$TRUNC)——概览模式,未逐文件读 hunk"
  echo "#### 实质提交(前 60 条,聚类用)"
  echo "$SUBJECTS" | head -60
  echo "#### 改动热点目录"
  echo "$CMP" | jq -r ".files[] | select($PFILTER) | .filename" \
    | grep -viE 'vendor/|\.pb\.go|generated|go\.(sum|mod)$' \
    | awk -F/ '{print $1"/"$2"/"$3}' | sort | uniq -c | sort -rn | head -15
  echo "(注:GitCode compare commits 不按 path 细分;truncated 时文件可能不全,看源链接)"
  exit 0
fi

echo "#### 实质提交(整区间,未按 path 细分)"
echo "$SUBJECTS" | head -40
echo "#### 信号文件(滤 vendor/generated$([ "${#PREFIXES[@]}" -gt 0 ] && echo " + 限定 component"))"
echo "$CMP" | jq -r "[.files[] | select($PFILTER) | select(.filename|test(\"vendor/|\\\\.pb\\\\.go|generated|go\\\\.(sum|mod)\$\")|not)] | sort_by(-( .changes // ((.additions//0)+(.deletions//0)) )) | .[] | \"\(.changes // ((.additions//0)+(.deletions//0)))\t\(.status)\t\(.filename)\"" | head -25
echo "#### 关键 patch 节选(真实代码 diff,每文件截断 80 行)"
echo "$CMP" | jq -r "
  [ .files[] | select($PFILTER) | select(.filename|test(\"vendor/|\\\\.pb\\\\.go|generated|go\\\\.(sum|mod)\$\")|not) ]
  | sort_by(
      (if (.filename|test(\"(^|/)(api|apis)/|config/crd|/crds?/|_types\\\\.go\$|docs/proposals|/design/\")) then 1000000 else 0 end)
      - (if (.filename|test(\"_test\\\\.go\$|_test\\\\.py\$|\\\\.spec\\\\.|/test\")) then 500000 else 0 end)
      + ( .changes // ((.additions//0)+(.deletions//0)) ) )
  | reverse | .[:8][]
  | \"@@FILE \(.filename) (\(.status))\n\(.patch // \"(无 patch:文件过大/二进制)\")\"
" | awk '/^@@FILE /{n=0;print;next}{n++; if(n<=80)print; else if(n==81)print "    …(本文件 hunk 截断,如需全量看源链接)"}'
echo "(注:GitCode compare 的 commits 不按 path 细分;truncated=$TRUNC 时大区间可能漏文件)"
