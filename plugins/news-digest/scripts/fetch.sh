#!/bin/bash
# 記事本文の取得スクリプト(macOS用)
# 指定した URL の本文テキストを取り出して標準出力に書く。
# まず直接取得し、本文が短すぎるときだけテキスト抽出サービス(r.jina.ai)を使う。
# JavaScript で本文を表示するサイトは直接取得では中身が取れないため。
#
# 使い方:
#   bash fetch.sh <URL>            # 既定の上限3000文字
#   bash fetch.sh <URL> 5000       # 上限を指定
set -u

URL="${1:-}"
MAX_CHARS="${2:-3000}"   # 1記事から渡す最大文字数(利用枠を使いすぎないため)
MIN_CHARS=800            # これ未満なら取得に失敗したとみなす

if [ -z "$URL" ]; then
  echo "URL を指定してください" >&2
  exit 1
fi

# news.google.com の転送 URL は元記事にたどり着けないため取得しない
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Googleニュースの転送リンクは、元記事の URL を調べてから取得する
resolve_google() {
  local gurl="$1"
  curl -sL --max-time 25 -A "Mozilla/5.0" "$gurl" -o "$TMP/g.html" 2>/dev/null || return 1
  local id sg ts
  id=$(grep -oE 'data-n-a-id="[^"]+"' "$TMP/g.html" | head -1 | sed 's/.*="//;s/"//')
  sg=$(grep -oE 'data-n-a-sg="[^"]+"' "$TMP/g.html" | head -1 | sed 's/.*="//;s/"//')
  ts=$(grep -oE 'data-n-a-ts="[^"]+"' "$TMP/g.html" | head -1 | sed 's/.*="//;s/"//')
  [ -z "$id" ] || [ -z "$sg" ] && return 1
  ID="$id" SG="$sg" TS="${ts:-0}" perl -e '
    my ($id,$sg,$ts) = ($ENV{ID}, $ENV{SG}, $ENV{TS});
    my $inner = qq{["garturlreq",[["ja","JP",["FINANCE_TOP_INDICES","WEB_TEST_1_0_0"],null,null,1,1,"JP:ja",null,null,null,null,null,null,null,0],"ja-JP","JP",1,[2,4,8],1,1,null,0,0,null,0],"$id",$ts,"$sg"]};
    my $esc = $inner; $esc =~ s/\\/\\\\/g; $esc =~ s/"/\\"/g;
    print qq{[[["Fbv4je","$esc",null,"generic"]]]};
  ' > "$TMP/req.txt"
  curl -s --max-time 25 -X POST "https://news.google.com/_/DotsSplashUi/data/batchexecute" \
    -H "Content-Type: application/x-www-form-urlencoded;charset=UTF-8" \
    -A "Mozilla/5.0" --data-urlencode "f.req@$TMP/req.txt" -o "$TMP/res.txt" 2>/dev/null || return 1
  grep -oE 'https?://[^\\"]{15,}' "$TMP/res.txt" | grep -vE 'news\.google|www\.google|gstatic' | head -1
}

case "$URL" in
  *news.google.com*)
    REAL=$(resolve_google "$URL" || true)
    if [ -n "${REAL:-}" ]; then
      URL="$REAL"
    else
      echo "本文なし: 転送リンクの解決に失敗しました。見出しだけで書き、(見出しのみ)と付けてください。"
      exit 0
    fi
    ;;
esac

# HTML からテキストを抜き出す
extract() {
  perl -CSD -0777 -pe '
    s{<script\b.*?</script>}{ }gsi;
    s{<style\b.*?</style>}{ }gsi;
    s{<nav\b.*?</nav>}{ }gsi;
    s{<footer\b.*?</footer>}{ }gsi;
    s{<[^>]+>}{ }gs;
    s/&#x([0-9a-fA-F]+);/chr(hex($1))/ge;
    s/&#(\d+);/chr($1)/ge;
    s/&quot;/"/g; s/&#39;/\x27/g; s/&lt;/</g; s/&gt;/>/g; s/&nbsp;/ /g; s/&amp;/&/g;
    s/\s+/ /gs;
  '
}

TEXT=""
if curl -sL --max-time 20 -A "Mozilla/5.0" "$URL" -o "$TMP/page.html" 2>/dev/null; then
  TEXT=$(extract < "$TMP/page.html")
fi

# 本文が取れていなければテキスト抽出サービスを使う。
# 文字数が足りない場合と、JavaScript を求める案内ページが返った場合が対象。
NEED_FALLBACK=0
[ "$(printf '%s' "$TEXT" | wc -m | tr -d ' ')" -lt "$MIN_CHARS" ] && NEED_FALLBACK=1
case "$TEXT" in
  *"JavaScriptが無効"*|*"JavaScript を有効"*|*"JavaScriptを有効"*|*"Please enable JavaScript"*|*"enable JavaScript"*|*"JavaScript is required"*|*"JavaScript is disabled"*)
    NEED_FALLBACK=1 ;;
esac

if [ "$NEED_FALLBACK" -eq 1 ]; then
  if curl -s --max-time 40 "https://r.jina.ai/$URL" -o "$TMP/page.txt" 2>/dev/null; then
    if [ -s "$TMP/page.txt" ] && ! grep -q '"code":4' "$TMP/page.txt"; then
      TEXT=$(tr '\n' ' ' < "$TMP/page.txt" | perl -CSD -pe 's/\s+/ /g')
    fi
  fi
fi

CHARS=$(printf '%s' "$TEXT" | wc -m | tr -d ' ')
if [ "$CHARS" -lt 200 ]; then
  echo "本文なし: 取得できませんでした。見出しだけで書き、(見出しのみ)と付けてください。"
  exit 0
fi

printf '%s' "$TEXT" | cut -c 1-"$((MAX_CHARS * 4))" | perl -CSD -ne "print substr(\$_, 0, $MAX_CHARS)"
echo
