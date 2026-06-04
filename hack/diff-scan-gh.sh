#!/usr/bin/env bash
# diff-scan-gh.sh REPO TASK [BRANCH]
#
# ai-radar diff-watch 的 GitHub 取数器(确定性部分,LLM 只负责研判)。
# - 从 TASK 的"上一篇 digest"里 grep 出本 REPO 的锚点 SHA(HTML 注释,渲染不可见)
# - compare base...HEAD,过滤 vendor/generated 噪声,打印原始材料
# - 打印今天该写进 digest 的新 ANCHOR 行
# 无锚点(首跑/断档)时退化为"近 3 天"窗口。脚本只读不写仓库,reset --hard 安全。
set -uo pipefail
REPO="${1:?usage: diff-scan-gh.sh REPO TASK [BRANCH]}"
TASK="${2:?task name required}"
BR="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
AUTH=(); [ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
AUTH+=(-H "Accept: application/vnd.github+json")
api(){ curl -s "${AUTH[@]}" "https://api.github.com/$1"; }

TODAY=$(date +%Y-%m-%d)
[ -z "$BR" ] && BR=$(api "repos/$REPO" | jq -r '.default_branch // "main"')
LATEST_REL=$(api "repos/$REPO/releases?per_page=1" | jq -r '.[0].tag_name // "—"')
HEAD_SHA=$(api "repos/$REPO/commits/$BR" | jq -r '.sha // empty')
[ -z "$HEAD_SHA" ] && { echo "### $REPO"; echo "FETCH FAILED (repo/branch 不可达,检查地址)"; exit 0; }

PREV=$(ls -1 "$ROOT"/digests/*-"$TASK".md 2>/dev/null | grep -v "/$TODAY-" | sort | tail -1)
BASE=""
WINDOW=""
FIRSTRUN=0
[ -n "$PREV" ] && BASE=$(grep -oE "ANCHOR repo=$REPO sha=[0-9a-f]+" "$PREV" 2>/dev/null | head -1 | sed 's/.*sha=//')
# 首跑(无上一篇 digest):只建立锚点 base=HEAD,不补历史 diff;从第 2 次起以本次 HEAD 为 base 做小增量。
[ -z "$BASE" ] && { BASE="$HEAD_SHA"; FIRSTRUN=1; }

echo "### $REPO"
echo "<!-- ANCHOR repo=$REPO sha=$HEAD_SHA branch=$BR release=$LATEST_REL scanned=$TODAY -->"
if [ -z "$BASE" ] || [ "$BASE" = "$HEAD_SHA" ]; then
  if [ "$FIRSTRUN" = 1 ]; then
    echo "- 首跑: 仅建立锚点 sha=${HEAD_SHA:0:8},从下次起跟踪增量 | Release: $LATEST_REL"
    echo "__BASELINE__"
  else
    echo "- 比较: ${BASE:0:8} -> ${HEAD_SHA:0:8} | Release: $LATEST_REL | 无新提交"
    echo "__EMPTY__"
  fi
  exit 0
fi

CMP=$(api "repos/$REPO/compare/$BASE...$HEAD_SHA")
AHEAD=$(echo "$CMP" | jq -r '.ahead_by // 0')
NFILES=$(echo "$CMP" | jq -r '.files|length')
echo "- 比较: ${BASE} -> ${HEAD_SHA:0:8} $WINDOW | ahead=$AHEAD | files=$NFILES | Release: $LATEST_REL"

SUBJECTS=$(echo "$CMP" | jq -r '.commits[].commit.message | split("\n")[0]' \
  | grep -viE '^(Merge|Bump |chore: bump|chore\(deps\)|build\(deps\)|\[ci|\[bot\]|Update .* Docker tag)' )
if [ -z "$SUBJECTS" ]; then echo "__EMPTY__ (仅 bump/CI/merge)"; exit 0; fi

# 自适应:大区间(首跑常见,>60 commit 或文件被 API 截断到 300)走概览模式,不逐文件读 hunk
if { [ "$AHEAD" -gt 60 ] 2>/dev/null; } || [ "$NFILES" -ge 300 ]; then
  echo "__OVERVIEW__ 首跑/大区间(ahead=$AHEAD,files=$NFILES$([ "$NFILES" -ge 300 ] && echo ",已被API截断"))——概览模式,未逐文件读 hunk"
  echo "#### 实质提交(取前 60 条,聚类用)"
  echo "$SUBJECTS" | head -60
  TOTAL=$(echo "$SUBJECTS" | wc -l); [ "$TOTAL" -gt 60 ] && echo "...(+$((TOTAL-60)) 条更多)"
  echo "#### 改动热点目录(top 顶层/二级目录)"
  echo "$CMP" | jq -r '.files[].filename' \
    | grep -viE 'vendor/|testdata/|\.pb\.go|generated|go\.(sum|mod)$' \
    | awk -F/ '{print $1"/"$2}' | sort | uniq -c | sort -rn | head -15
  echo "#### release note(供 breaking/deprecation 判断)"
  api "repos/$REPO/releases?per_page=1" | jq -r '.[0].body // "(无 release body)"' | head -40
  exit 0
fi

echo "#### 实质提交"
echo "$SUBJECTS" | head -40
echo "#### 信号文件(滤 vendor/generated,按改动量)"
echo "$CMP" | jq -r '.files[] | [.changes,.status,.filename] | @tsv' \
  | awk -F'\t' '$3 !~ /vendor\/|testdata\/|\.pb\.go|generated|go\.(sum|mod)$/' \
  | sort -t"$(printf '\t')" -k1 -rn | head -25
echo "#### 关键 patch 节选(真实代码 diff,符号级总结的唯一依据;每文件截断 80 行)"
# 信号文件(api/crd/_types/proposal)无论改动大小一律优先纳入,再补 top 大文件;每文件一段真实 hunk
echo "$CMP" | jq -r '
  [ .files[] | select(.filename|test("vendor/|testdata/|\\.pb\\.go|generated|go\\.(sum|mod)$")|not) ]
  | sort_by(
      (if (.filename|test("(^|/)(api|apis)/|config/crd|/crds?/|_types\\.go$|docs/proposals|/design/")) then 1000000 else 0 end)
      - (if (.filename|test("_test\\.go$|_test\\.py$|\\.spec\\.|/test")) then 500000 else 0 end)
      + .changes )
  | reverse | .[:8][]
  | "@@FILE \(.filename) (\(.status) +\(.additions)/-\(.deletions))\n\(.patch // "(无 patch:文件过大或二进制,需 raw 单独取)")"
' | awk '/^@@FILE /{n=0;print;next}{n++; if(n<=80)print; else if(n==81)print "    …(本文件 hunk 截断,如需全量看源链接)"}'
echo "#### 重要改变探测(API/CRD/proposal 路径命中)"
echo "$CMP" | jq -r '.files[].filename' \
  | grep -iE '(^|/)(api|apis)/|config/crd|/crds?/|docs/proposals|/design/|_types\.go$' | sort -u | head -15 \
  || echo "(无 API/CRD 路径命中)"
