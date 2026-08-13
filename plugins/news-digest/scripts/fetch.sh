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
JINA_TRIES=2             # テキスト抽出サービスを試す回数
RETRY_WAIT=3             # 取り直しまでに待つ秒数(取得制限に当たったときのため)

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

chars() { printf '%s' "$1" | wc -m | tr -d ' '; }

# 認証画面や案内ページに出る文言が含まれるかを調べる。
# これは「本文が取れていないかもしれない」という手がかりであって、それだけでは失敗と決めない。
# 広告ブロックの警告のように、本文が読めるページにも常に埋め込まれている文言があるため。
# 実際に失敗かどうかは、最後に文字数で判定する。
has_notice() {
  case "$1" in
    *"Just a moment"*|*"Enable JavaScript and cookies to continue"*|*"Checking your browser"*|*"cf-browser-verification"*|*"コンテンツブロックが有効"*)
      return 0 ;;
  esac
  case "$1" in
    *"JavaScriptが無効"*|*"JavaScript を有効"*|*"JavaScriptを有効"*|*"Please enable JavaScript"*|*"enable JavaScript"*|*"JavaScript is required"*|*"JavaScript is disabled"*)
      return 0 ;;
  esac
  return 1
}

# 取り直すときに、前回と違う URL にするためのパラメータを足す
bust() {
  case "$1" in
    *\?*) printf '%s&_ndg=%s' "$1" "$2" ;;
    *)    printf '%s?_ndg=%s' "$1" "$2" ;;
  esac
}

# テキスト抽出サービスから本文を取る。
# 1回目が短かったときは、取得制限に当たっている場合と、誤ったページが
# 向こうにキャッシュされている場合がある。そのため、間を置いたうえで、
# URL にパラメータを足して(=別の URL として)取り直す。
jina_text() {
  local n=1 target t
  while [ "$n" -le "$JINA_TRIES" ]; do
    if [ "$n" -eq 1 ]; then
      target="$1"
    else
      target=$(bust "$1" "$n")
      sleep "$RETRY_WAIT"
    fi
    if curl -s --max-time 40 "https://r.jina.ai/$target" -o "$TMP/jina.txt" 2>/dev/null \
       && [ -s "$TMP/jina.txt" ] && ! grep -q '"code":4' "$TMP/jina.txt"; then
      t=$(tr '\n' ' ' < "$TMP/jina.txt" | perl -CSD -pe 's/\s+/ /g')
      if [ "$(chars "$t")" -ge "$MIN_CHARS" ]; then
        printf '%s' "$t"
        return 0
      fi
    fi
    n=$((n+1))
  done
  return 1
}

TEXT=""
if curl -sL --max-time 20 -A "Mozilla/5.0" "$URL" -o "$TMP/page.html" 2>/dev/null; then
  TEXT=$(extract < "$TMP/page.html")
fi

# 直接取得が短いか、案内ページの文言を含むときはテキスト抽出サービスも試す。
# 取れた本文のほうが長ければそちらを使う(直接取得が本文を含んでいることもあるため)。
if [ "$(chars "$TEXT")" -lt "$MIN_CHARS" ] || has_notice "$TEXT"; then
  ALT=$(jina_text "$URL" || true)
  if [ -n "${ALT:-}" ] && [ "$(chars "$ALT")" -gt "$(chars "$TEXT")" ]; then
    TEXT="$ALT"
  fi
fi

# 規定の長さに届かないものは、本文ではなくメニューや案内の断片とみなす。
# 中途半端な文字列を本文として渡すと、印の付かない誤った要約になってしまうため。
if [ "$(chars "$TEXT")" -lt "$MIN_CHARS" ]; then
  if has_notice "$TEXT"; then
    echo "本文なし: サイトが自動アクセスを拒否しました。見出しだけで書き、(見出しのみ)と付けてください。"
  else
    echo "本文なし: 取得できませんでした。見出しだけで書き、(見出しのみ)と付けてください。"
  fi
  exit 0
fi

printf '%s' "$TEXT" | cut -c 1-"$((MAX_CHARS * 4))" | perl -CSD -ne "print substr(\$_, 0, $MAX_CHARS)"
echo
