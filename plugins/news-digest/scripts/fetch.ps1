# 記事本文の取得スクリプト(Windows用)
# 指定した URL の本文テキストを取り出して標準出力に書く。
# まず直接取得し、本文が短すぎるときだけテキスト抽出サービス(r.jina.ai)を使う。
# JavaScript で本文を表示するサイトは直接取得では中身が取れないため。
#
# 使い方:
#   powershell -ExecutionPolicy Bypass -File fetch.ps1 -Url "<URL>"
#   powershell -ExecutionPolicy Bypass -File fetch.ps1 -Url "<URL>" -MaxChars 5000
param(
    [Parameter(Mandatory=$true)][string]$Url,
    [int]$MaxChars = 3000   # 1記事から渡す最大文字数(利用枠を使いすぎないため)
)

$MinChars = 800             # これ未満なら取得に失敗したとみなす
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# news.google.com の転送 URL は元記事にたどり着けないため取得しない
# Googleニュースの転送リンクは、元記事の URL を調べてから取得する
function Resolve-GoogleNews([string]$gurl) {
    try {
        $page = Get-Page $gurl
        if (-not $page) { [Console]::Error.WriteLine("転送ページを取得できません"); return "" }
        $id = [regex]::Match($page, 'data-n-a-id="([^"]+)"').Groups[1].Value
        $sg = [regex]::Match($page, 'data-n-a-sg="([^"]+)"').Groups[1].Value
        $ts = [regex]::Match($page, 'data-n-a-ts="([^"]+)"').Groups[1].Value
        if (-not $id -or -not $sg) { [Console]::Error.WriteLine("転送ページに必要な値がありません"); return "" }
        if (-not $ts) { $ts = "0" }

        $inner = '["garturlreq",[["ja","JP",["FINANCE_TOP_INDICES","WEB_TEST_1_0_0"],null,null,1,1,"JP:ja",null,null,null,null,null,null,null,0],"ja-JP","JP",1,[2,4,8],1,1,null,0,0,null,0],"' + $id + '",' + $ts + ',"' + $sg + '"]'
        $esc = $inner.Replace('\', '\\').Replace('"', '\"')
        $freq = '[[["Fbv4je","' + $esc + '",null,"generic"]]]'

        $res = ""
        if ($script:curlExe) {
            # mac 版と同じ経路。要求文字列はファイルに書いて渡す(コマンドラインの長さ制限と引用符の問題を避けるため)
            $tmp = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($tmp, $freq, (New-Object System.Text.UTF8Encoding($false)))
            try {
                $out = & $script:curlExe.Source -s --max-time 25 -X POST "https://news.google.com/_/DotsSplashUi/data/batchexecute" `
                    -H "Content-Type: application/x-www-form-urlencoded;charset=UTF-8" `
                    -A "Mozilla/5.0" --data-urlencode "f.req@$tmp" 2>$null
                if ($out) { $res = ($out -join "`n") }
            } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
        }
        if (-not $res) {
            $body = "f.req=" + [uri]::EscapeDataString($freq)
            $w2 = New-Object System.Net.WebClient
            $w2.Encoding = [System.Text.Encoding]::UTF8
            $w2.Headers.Add("User-Agent", "Mozilla/5.0")
            $w2.Headers.Add("Content-Type", "application/x-www-form-urlencoded;charset=UTF-8")
            $res = $w2.UploadString("https://news.google.com/_/DotsSplashUi/data/batchexecute", "POST", $body)
        }
        if (-not $res) { [Console]::Error.WriteLine("解決の問い合わせに応答がありません"); return "" }

        foreach ($m in [regex]::Matches($res, 'https?://[^\\"]{15,}')) {
            if ($m.Value -notmatch 'news\.google|www\.google|gstatic') { return $m.Value }
        }
        [Console]::Error.WriteLine("応答に元記事の URL が含まれていません")
    } catch {
        [Console]::Error.WriteLine("転送リンクの解決で例外: $($_.Exception.Message)")
    }
    return ""
}

if ($Url -match 'news\.google\.com') {
    $real = Resolve-GoogleNews $Url
    if ($real) { $Url = $real }
    else {
        Write-Output "本文なし: 転送リンクの解決に失敗しました。見出しだけで書き、(見出しのみ)と付けてください。"
        exit 0
    }
}

# ページの取得。Windows 10 以降に標準搭載の curl.exe を優先して使う。
# .NET の通信は一部のサイト(Cloudflare 配下など)から拒否されるため。
$curlExe = (Get-Command curl.exe -ErrorAction SilentlyContinue)
function Get-Page([string]$url) {
    if ($script:curlExe) {
        try {
            $out = & $script:curlExe.Source -sL --max-time 25 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36" $url 2>$null
            if ($out) { return ($out -join "`n") }
        } catch { }
    }
    try {
        $w = New-Object System.Net.WebClient
        $w.Encoding = [System.Text.Encoding]::UTF8
        $w.Headers.Add("User-Agent", "Mozilla/5.0")
        return $w.DownloadString($url)
    } catch { return $null }
}

function Convert-HtmlToText([string]$html) {
    if (-not $html) { return "" }
    $t = $html
    $t = [regex]::Replace($t, '(?is)<script\b.*?</script>', ' ')
    $t = [regex]::Replace($t, '(?is)<style\b.*?</style>', ' ')
    $t = [regex]::Replace($t, '(?is)<nav\b.*?</nav>', ' ')
    $t = [regex]::Replace($t, '(?is)<footer\b.*?</footer>', ' ')
    $t = [regex]::Replace($t, '(?s)<[^>]+>', ' ')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = [regex]::Replace($t, '\s+', ' ')
    return $t.Trim()
}

$wc = New-Object System.Net.WebClient
$wc.Encoding = [System.Text.Encoding]::UTF8
$wc.Headers.Add("User-Agent", "Mozilla/5.0")

$text = ""
$text = Convert-HtmlToText (Get-Page $Url)

# 本文が取れていなければテキスト抽出サービスを使う。
# 文字数が足りない場合と、JavaScript を求める案内ページが返った場合が対象。
$needFallback = $false
if ($text.Length -lt $MinChars) { $needFallback = $true }
if ($text -match 'JavaScriptが無効|JavaScript ?を有効|Please enable JavaScript|enable JavaScript|JavaScript is required|JavaScript is disabled') {
    $needFallback = $true
}

if ($needFallback) {
    try {
        $alt = Get-Page "https://r.jina.ai/$Url"
        if ($alt -and $alt -notmatch '"code":4') {
            $text = [regex]::Replace($alt, '\s+', ' ').Trim()
        }
    } catch { }
}

if ($text.Length -lt 200) {
    Write-Output "本文なし: 取得できませんでした。見出しだけで書き、(見出しのみ)と付けてください。"
    exit 0
}

if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars) }
Write-Output $text
