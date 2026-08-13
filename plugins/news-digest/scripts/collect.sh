#!/bin/bash
# ニュース収集スクリプト(macOS用)
# 情報源(RSS/Atom/RDF)からキーワードの新着を取得し、items.txt に整形して保存する。
#
# 情報源は、実行フォルダに sources.txt があればそれを、なければ既定の2本を使う。
# sources.txt は 1 行 1 URL。URL 内の {KEYWORD} は引数のキーワードに置き換わる。
# # で始まる行と空行は無視する。
#
# 使い方:
#   bash collect.sh              # 既定キーワード(生成AI)で収集
#   bash collect.sh "Claude"     # キーワードを指定して収集
set -u

KEYWORD="${1:-生成AI}"
PER_SOURCE=20          # 各情報源から残す最大件数
OUT="items.txt"
SRC_FILE="sources.txt"
SEEN_FILE="seen.txt"   # 既読記録。削除するとすべて新着として扱う
SEEN_KEEP=30000        # 既読記録として保持する最大件数(約140日分。フィードは最長30日分を保持するため十分な余裕を持たせる)

DEFAULT_SOURCES=(
  "https://news.google.com/rss/search?q={KEYWORD}&hl=ja&gl=JP&ceid=JP:ja"
  "https://b.hatena.ne.jp/q/{KEYWORD}?mode=rss&target=text"
)

# URLエンコード(全バイトを%XX化)
enc() { printf '%s' "$1" | od -An -v -tx1 | awk '{for(i=1;i<=NF;i++) printf "%%%s",$i}'; }
ENCKW=$(enc "$KEYWORD")

# 情報源リストを決定(bash 3.2 でも動くよう while read で読む)
SOURCES=()
if [ -f "$SRC_FILE" ]; then
  while IFS= read -r line; do
    case "$line" in ""|\#*) continue;; esac
    SOURCES+=("$line")
  done < "$SRC_FILE"
fi
if [ ${#SOURCES[@]} -eq 0 ]; then
  SOURCES=("${DEFAULT_SOURCES[@]}")
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for src in "${SOURCES[@]}"; do
  url="${src//\{KEYWORD\}/$ENCKW}"
  host=$(printf '%s' "$url" | sed -E 's#^https?://([^/]+).*#\1#')
  if ! curl -sL --max-time 25 "$url" -o "$TMP/feed.xml"; then
    echo "取得できませんでした: $url" >&2
    continue
  fi
  # RSS/RDF(item) と Atom(entry) の両方に対応。link はテキスト形式と href 属性の両方。
  # はてなブックマーク数があれば末尾に付ける。
  PER_SOURCE="$PER_SOURCE" perl -CSD -0777 -ne '
    use utf8;
    my $max = $ENV{PER_SOURCE};
    my $n = 0;
    while (/<(item|entry)\b[^>]*>(.*?)<\/\1>/gs) {
      my $b = $2;
      my ($title) = $b =~ /<title[^>]*>(.*?)<\/title>/s;
      my $link;
      if ($b =~ /<link[^>]*\bhref="([^"]+)"/s) { $link = $1; }
      elsif ($b =~ /<link[^>]*>(.*?)<\/link>/s) { $link = $1; }
      my ($date) = $b =~ /<(?:pubDate|dc:date|updated|published)[^>]*>(.*?)<\/(?:pubDate|dc:date|updated|published)>/s;
      my ($bc)   = $b =~ /<hatena:bookmarkcount[^>]*>(\d+)<\/hatena:bookmarkcount>/s;
      $date = "" unless defined $date;
      next unless (defined $title && defined $link);
      for ($title, $link, $date) {
        s/<!\[CDATA\[(.*?)\]\]>/$1/gs;
        s/&#x([0-9a-fA-F]+);/chr(hex($1))/ge;
        s/&#(\d+);/chr($1)/ge;
        s/&quot;/"/g; s/&#39;/\x27/g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/&/g;
        s/[\t\r\n]+/ /g; s/^\s+//; s/\s+$//;
      }
      next if $title eq "";
      my $extra = (defined $bc) ? "\t${bc}ブクマ" : "";
      print "\x01\t$date\t$title\t$link$extra\n";
      last if ++$n >= $max;
    }
  ' "$TMP/feed.xml" | sed "s/^$(printf '\x01')/$host/" >> "$TMP/parsed.txt"
done

touch "$TMP/parsed.txt" "$SEEN_FILE"

# 既読を除き、新着だけを残す。同じ実行内の重複も除く。
#
# 同じ記事が複数の情報源から入ってくるため、タイトルをそのまま比べても重複を取り除けない。
# Googleニュースは末尾に「 - 媒体名」を付け、はてなは全角スペースを使い、
# ブックマークのページは『〜』へのコメントという題になる。そこで形を揃えてから比べる。
#
# 重複したときは Googleニュース以外を残す。Googleニュースのリンクは転送用で、
# 記事そのものの URL ではないため、レポートに載せるリンクとして望ましくないため。
SEEN_FILE="$SEEN_FILE" PARSED="$TMP/parsed.txt" perl -CSD -e '
  use utf8;
  sub norm {
    my $t = shift;
    $t =~ s/^『(.*)』へのコメント$/$1/;          # はてなのブックマークページ
    $t =~ s/\x{3000}/ /g;                        # 全角スペース
    $t =~ s/\s+/ /g; $t =~ s/^\s+//; $t =~ s/\s+$//;
    my $c = $t;
    $c =~ s/\s+[-|｜–—]\s+[^-|｜–—]{1,30}$//;     # 末尾の媒体名(「 - ASCII.jp」「 | Business Insider Japan」など)
    $t = $c if length($c) >= 10;                 # 削りすぎたときは元に戻す
    $t =~ s/\s*\(\d+\/\d+\)\s*$//;               # (1/5) のようなページ番号。媒体名を外した後に見る
    $t =~ s/\s+$//;
    return $t;
  }
  my (%seen, %other);
  if (open(my $s, "<:utf8", $ENV{SEEN_FILE})) {
    while (<$s>) { chomp; next unless /\S/; $seen{norm($_)} = 1 }   # 過去の記録も同じ形に揃える
    close $s;
  }
  my @lines;
  open(my $p, "<:utf8", $ENV{PARSED}) or exit 0;
  while (<$p>) { chomp; push @lines, $_ if /\S/ }
  close $p;
  for my $l (@lines) {
    my @f = split /\t/, $l, -1;
    next if @f < 3;
    $other{norm($f[2])} = 1 if $f[0] ne "news.google.com";
  }
  for my $l (@lines) {
    my @f = split /\t/, $l, -1;
    next if @f < 3;
    my $k = norm($f[2]);
    next if $k eq "" || $seen{$k};
    next if $f[0] eq "news.google.com" && $other{$k};
    $seen{$k} = 1;
    print "$l\n";
  }
' > "$TMP/new.txt"

{
  echo "# キーワード: $KEYWORD / 取得日時: $(date '+%Y-%m-%d %H:%M')"
  echo "# 形式: ソース <TAB> 日付 <TAB> タイトル <TAB> URL (はてなは末尾にブクマ数)"
  echo "# 内容: 前回以降の新着のみ(既読は $SEEN_FILE で管理。すべて見たいときは削除する)"
  cat "$TMP/new.txt"
} > "$OUT"

# 新着のタイトルを既読に追加し、記録が増えすぎないよう新しいものだけ残す
cut -f3 "$TMP/new.txt" >> "$SEEN_FILE"
tail -n "$SEEN_KEEP" "$SEEN_FILE" > "$TMP/seen.trim" && mv "$TMP/seen.trim" "$SEEN_FILE"

allcnt=$(grep -c . "$TMP/parsed.txt" || true)
newcnt=$(grep -c . "$TMP/new.txt" || true)
echo "取得: ${allcnt}件中 新着 ${newcnt}件 -> $OUT"
