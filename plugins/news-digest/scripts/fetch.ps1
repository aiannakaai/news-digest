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

$MinChars  = 800            # これ未満なら取得に失敗したとみなす
$JinaTries = 2              # テキスト抽出サービスを試す回数
$RetryWait = 3              # 取り直しまでに待つ秒数(取得制限に当たったときのため)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# news.google.com の転送 URL は元記事にたどり着けないため取得しない
# Googleニュースの転送リンクは、元記事の URL を調べてから取得する
$curlExe = (Get-Command curl.exe -ErrorAction SilentlyContinue)
function Get-Page([string]$url) {
    if ($script:curlExe) {
        # 標準出力経由だと文字コードが壊れるため、いったんファイルに保存してから読む
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            & $script:curlExe.Source -sL --max-time 25 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36" -o $tmp $url 2>$null | Out-Null
            if ((Test-Path $tmp) -and ((Get-Item $tmp).Length -gt 0)) {
                $bytes = [System.IO.File]::ReadAllBytes($tmp)
                # 文字コードは HTML の宣言から判定する。既定は UTF-8
                $head = [System.Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(3000, $bytes.Length))
                $enc = [System.Text.Encoding]::UTF8
                if ($head -match '(?i)charset\s*=\s*["'']?\s*(shift[_-]?jis|x-sjis|windows-31j)') {
                    $enc = [System.Text.Encoding]::GetEncoding("shift_jis")
                } elseif ($head -match '(?i)charset\s*=\s*["'']?\s*(euc-jp)') {
                    $enc = [System.Text.Encoding]::GetEncoding("euc-jp")
                }
                return $enc.GetString($bytes)
            }
        } catch { } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }
    try {
        $w = New-Object System.Net.WebClient
        $w.Encoding = [System.Text.Encoding]::UTF8
        $w.Headers.Add("User-Agent", "Mozilla/5.0")
        return $w.DownloadString($url)
    } catch { return $null }
}

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

# 認証画面や案内ページに出る文言が含まれるかを調べる。
# これは「本文が取れていないかもしれない」という手がかりであって、それだけでは失敗と決めない。
# 広告ブロックの警告のように、本文が読めるページにも常に埋め込まれている文言があるため。
# 実際に失敗かどうかは、最後に文字数で判定する。
$noticePattern = 'Just a moment|Enable JavaScript and cookies to continue|Checking your browser|cf-browser-verification|コンテンツブロックが有効|JavaScriptが無効|JavaScript ?を有効|Please enable JavaScript|enable JavaScript|JavaScript is required|JavaScript is disabled'

# 取り直すときに、前回と違う URL にするためのパラメータを足す
function Add-Bust([string]$url, [int]$n) {
    # 変数名が続きの文字まで飲み込まないよう ${} で囲む
    if ($url -match '\?') { return "${url}&_ndg=${n}" } else { return "${url}?_ndg=${n}" }
}

# テキスト抽出サービスから本文を取る。
# 1回目が短かったときは、取得制限に当たっている場合と、誤ったページが
# 向こうにキャッシュされている場合がある。そのため、間を置いたうえで、
# URL にパラメータを足して(=別の URL として)取り直す。
function Get-JinaText([string]$url) {
    for ($n = 1; $n -le $script:JinaTries; $n++) {
        $target = $url
        if ($n -gt 1) {
            $target = Add-Bust $url $n
            Start-Sleep -Seconds $script:RetryWait
        }
        try {
            $alt = Get-Page "https://r.jina.ai/$target"
            if ($alt -and $alt -notmatch '"code":4') {
                $t = [regex]::Replace($alt, '\s+', ' ').Trim()
                if ($t.Length -ge $script:MinChars) { return $t }
            }
        } catch { }
    }
    return ""
}

$text = Convert-HtmlToText (Get-Page $Url)

# 直接取得が短いか、案内ページの文言を含むときはテキスト抽出サービスも試す。
# 取れた本文のほうが長ければそちらを使う(直接取得が本文を含んでいることもあるため)。
if ($text.Length -lt $MinChars -or $text -match $noticePattern) {
    $alt = Get-JinaText $Url
    if ($alt -and $alt.Length -gt $text.Length) { $text = $alt }
}

# 規定の長さに届かないものは、本文ではなくメニューや案内の断片とみなす。
# 中途半端な文字列を本文として渡すと、印の付かない誤った要約になってしまうため。
if ($text.Length -lt $MinChars) {
    if ($text -match $noticePattern) {
        Write-Output "本文なし: サイトが自動アクセスを拒否しました。見出しだけで書き、(見出しのみ)と付けてください。"
    } else {
        Write-Output "本文なし: 取得できませんでした。見出しだけで書き、(見出しのみ)と付けてください。"
    }
    exit 0
}

if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars) }
Write-Output $text
