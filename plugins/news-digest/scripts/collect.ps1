# ニュース収集スクリプト(Windows用)
# 情報源(RSS/Atom/RDF)からキーワードの新着を取得し、items.txt に整形して保存する。
#
# 情報源は、実行フォルダに sources.txt があればそれを、なければ既定の2本を使う。
# sources.txt は 1 行 1 URL。URL 内の {KEYWORD} は引数のキーワードに置き換わる。
# # で始まる行と空行は無視する。
#
# 使い方:
#   powershell -ExecutionPolicy Bypass -File collect.ps1
#   powershell -ExecutionPolicy Bypass -File collect.ps1 -Keyword "Claude"
param([string]$Keyword = "生成AI")

$PerSource = 20   # 各情報源から残す最大件数
$SeenKeep  = 3000 # 既読記録として保持する最大件数
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$enc = [uri]::EscapeDataString($Keyword)

$defaultSources = @(
    "https://news.google.com/rss/search?q={KEYWORD}&hl=ja&gl=JP&ceid=JP:ja",
    "https://b.hatena.ne.jp/q/{KEYWORD}?mode=rss&target=text"
)

# 情報源リストを決定
$srcFile = Join-Path (Get-Location).Path "sources.txt"
if (Test-Path $srcFile) {
    $sources = Get-Content $srcFile -Encoding UTF8 |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' }
} else {
    $sources = @()
}
if (-not $sources -or @($sources).Count -eq 0) { $sources = $defaultSources }

$wc = New-Object System.Net.WebClient
$wc.Encoding = [System.Text.Encoding]::UTF8
# UA を付けないと取得を拒否するサイトがある
$wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36")
$wc.Headers.Add("Accept", "application/rss+xml, application/atom+xml, application/xml, text/xml, */*")

# フィードの取得。Windows 10 以降に標準搭載の curl.exe を優先して使う。
# .NET の通信は一部のサイト(Cloudflare 配下など)から拒否されるため。
$curlExe = (Get-Command curl.exe -ErrorAction SilentlyContinue)
function Get-Feed([string]$url) {
    if ($script:curlExe) {
        try {
            $out = & $script:curlExe.Source -sL --max-time 25 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36" $url 2>$null
            if ($out) { return ($out -join "`n") }
        } catch { }
    }
    try { return $wc.DownloadString($url) } catch { return $null }
}

# 既読記録を読み込む(seen.txt が無ければ空。削除するとすべて新着になる)
$seenPath = Join-Path (Get-Location).Path "seen.txt"
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
if (Test-Path $seenPath) {
    foreach ($s in (Get-Content $seenPath -Encoding UTF8)) {
        if ($s -match '\S') { [void]$seen.Add($s) }
    }
}

$newLines = New-Object System.Collections.Generic.List[string]
$newTitles = New-Object System.Collections.Generic.List[string]
$total = 0
foreach ($src in $sources) {
    $url = $src -replace '\{KEYWORD\}', $enc
    try { $srcHost = ([uri]$url).Host } catch { $srcHost = "source" }
    $content = Get-Feed $url
    if (-not $content) {
        [Console]::Error.WriteLine("取得できませんでした: $url")
        continue
    }
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.LoadXml($content)
    } catch {
        [Console]::Error.WriteLine("読み取れませんでした: $url ($($_.Exception.Message))")
        continue
    }
    # RSS/RDF(item) と Atom(entry) の両方に対応(名前空間を無視して local-name で拾う)
    $nodes = $doc.SelectNodes("//*[local-name()='item' or local-name()='entry']")
    $n = 0
    foreach ($node in $nodes) {
        $titleNode = $node.SelectSingleNode("*[local-name()='title']")
        if (-not $titleNode) { continue }
        $title = $titleNode.InnerText.Trim()
        if ($title -eq "") { continue }

        $linkNode = $node.SelectSingleNode("*[local-name()='link']")
        $link = ""
        if ($linkNode) {
            if ($linkNode.Attributes -and $linkNode.Attributes["href"]) {
                $link = $linkNode.Attributes["href"].Value
            } else {
                $link = $linkNode.InnerText.Trim()
            }
        }
        if ($link -eq "") { continue }

        $dateNode = $node.SelectSingleNode("*[local-name()='pubDate' or local-name()='date' or local-name()='updated' or local-name()='published']")
        $date = if ($dateNode) { $dateNode.InnerText.Trim() } else { "" }

        $bcNode = $node.SelectSingleNode("*[local-name()='bookmarkcount']")
        $extra = if ($bcNode) { "`t$($bcNode.InnerText)ブクマ" } else { "" }

        $t = ($title -replace "[`t`r`n]+", " ")
        $total++
        $n++
        # 既読(タイトルが一致するもの)は除く。同じ実行内の重複も除く
        if (-not $seen.Contains($t)) {
            [void]$seen.Add($t)
            $newLines.Add("$srcHost`t$date`t$t`t$link$extra")
            $newTitles.Add($t)
        }
        if ($n -ge $PerSource) { break }
    }
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# キーワード: $Keyword / 取得日時: " + (Get-Date -Format "yyyy-MM-dd HH:mm"))
$lines.Add("# 形式: ソース <TAB> 日付 <TAB> タイトル <TAB> URL (はてなは末尾にブクマ数)")
$lines.Add("# 内容: 前回以降の新着のみ(既読は seen.txt で管理。すべて見たいときは削除する)")
$lines.AddRange($newLines)

$outPath = Join-Path (Get-Location).Path "items.txt"
[System.IO.File]::WriteAllLines($outPath, $lines, (New-Object System.Text.UTF8Encoding($true)))

# 新着のタイトルを既読に追加し、記録が増えすぎないよう新しいものだけ残す
$allSeen = New-Object System.Collections.Generic.List[string]
if (Test-Path $seenPath) { $allSeen.AddRange([string[]](Get-Content $seenPath -Encoding UTF8)) }
$allSeen.AddRange($newTitles)
if ($allSeen.Count -gt $SeenKeep) {
    $allSeen = $allSeen.GetRange($allSeen.Count - $SeenKeep, $SeenKeep)
}
[System.IO.File]::WriteAllLines($seenPath, $allSeen, (New-Object System.Text.UTF8Encoding($true)))

Write-Output ("取得: {0}件中 新着 {1}件 -> items.txt" -f $total, $newLines.Count)
