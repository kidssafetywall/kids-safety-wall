#Requires -Version 5.1
param(
    [int]$DelayMs = 800
)

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path
$DataDir   = Join-Path $ScriptDir "..\data"
$OutPath   = Join-Path $DataDir "quasi-public.json"

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$enc     = [System.Text.UTF8Encoding]::new($false)
$BaseUrl = "https://ap.ece.moe.edu.tw/webecems/pubSearch.aspx"
$ua      = "KidsSafetyWall/1.0 (jbseric66060@gmail.com)"

function GetField([string]$h, [string]$pat) {
    return [regex]::Match($h, $pat).Groups[1].Value
}

function Get-PageItems([string]$r) {
    $results = [System.Collections.Generic.List[hashtable]]::new()
    $ms = [regex]::Matches($r, 'lblSchName_(\d+)">([^<]+)</span>')
    foreach ($m in $ms) {
        $idx  = $m.Groups[1].Value
        $name = $m.Groups[2].Value.Replace("臺","台").Trim()
        $city = GetField $r "lblCity_${idx}`">([^<]+)</span>"
        $dist = GetField $r "lblArea_${idx}`">([^<]+)</span>"
        $results.Add(@{ name=$name; city=$city.Replace("臺","台").Trim(); district=$dist.Trim() })
    }
    return ,$results
}

Write-Host "=== 準公共幼兒園抓取工具 ==="
Write-Host "來源：教育部全國教保資訊網"
Write-Host ""

# ── Step 1: GET for initial VIEWSTATE ─────────────────────────────────────
Write-Host "取得表單 Token..."
$getResp = Invoke-WebRequest -Uri $BaseUrl -UseBasicParsing -SessionVariable sess -TimeoutSec 20 -Headers @{"User-Agent"=$ua}
$html    = $getResp.Content

# ── Step 2: POST search (page 1) ──────────────────────────────────────────
Write-Host "搜尋準公共幼兒園（ckSPub3=on）..."
$r = (Invoke-WebRequest -Uri $BaseUrl -Method POST -Body @{
    "__EVENTTARGET"        = ""
    "__EVENTARGUMENT"      = ""
    "__LASTFOCUS"          = ""
    "__VIEWSTATE"          = (GetField $html 'id="__VIEWSTATE"\s+value="([^"]+)"')
    "__VIEWSTATEGENERATOR" = (GetField $html 'id="__VIEWSTATEGENERATOR"\s+value="([^"]+)"')
    "__VIEWSTATEENCRYPTED" = ""
    "__EVENTVALIDATION"    = (GetField $html 'id="__EVENTVALIDATION"\s+value="([^"]+)"')
    "ddlKey"               = ""
    "txtKey"               = ""
    "ddlCityS"             = ""
    "ddlAreaS"             = ""
    "ckSPub3"              = "on"
    "btnSearch"            = "搜尋"
} -WebSession $sess -UseBasicParsing -Headers @{"User-Agent"=$ua} -TimeoutSec 30).Content

$totalPages = [int](GetField $r 'lblTotalPage">(\d+)</span>')
$total      = [int](GetField $r 'lblTotalCount">(\d+)</span>')
Write-Host "共 $total 筆，$totalPages 頁"

$allSchools = [System.Collections.Generic.List[hashtable]]::new()
$p1 = Get-PageItems $r
foreach ($i in $p1) { $allSchools.Add($i) }
Write-Host "  頁  1/$totalPages : $($p1.Count) 筆"

# ── Step 3: Loop pages 2..totalPages ──────────────────────────────────────
for ($p = 2; $p -le $totalPages; $p++) {
    Start-Sleep -Milliseconds $DelayMs
    try {
        $r = (Invoke-WebRequest -Uri $BaseUrl -Method POST -Body @{
            "__EVENTTARGET"        = "PageControl1`$lbNextPage"
            "__EVENTARGUMENT"      = ""
            "__LASTFOCUS"          = ""
            "__VIEWSTATE"          = (GetField $r 'id="__VIEWSTATE"\s+value="([^"]+)"')
            "__VIEWSTATEGENERATOR" = (GetField $r 'id="__VIEWSTATEGENERATOR"\s+value="([^"]+)"')
            "__VIEWSTATEENCRYPTED" = ""
            "__EVENTVALIDATION"    = (GetField $r 'id="__EVENTVALIDATION"\s+value="([^"]+)"')
            "ddlKey"               = ""
            "txtKey"               = ""
            "ddlCityS"             = ""
            "ddlAreaS"             = ""
            "ckSPub3"              = "on"
            "PageControl1`$txtPages" = "$($p - 1)"
        } -WebSession $sess -UseBasicParsing -Headers @{"User-Agent"=$ua} -TimeoutSec 30).Content

        $items = Get-PageItems $r
        foreach ($i in $items) { $allSchools.Add($i) }
        if ($p % 20 -eq 0 -or $p -eq $totalPages) {
            Write-Host "  頁 $($p.ToString().PadLeft(3))/$totalPages : 累計 $($allSchools.Count) 筆"
        }
    } catch {
        Write-Host "  [ERR] 頁 $p : $_"
    }
}

# ── Step 4: Save ───────────────────────────────────────────────────────────
$arr = @($allSchools)
[IO.File]::WriteAllText($OutPath, ($arr | ConvertTo-Json -Depth 3), $enc)

Write-Host ""
Write-Host "============================="
Write-Host "  抓取完成：$($allSchools.Count) 筆"
Write-Host "  儲存至：$OutPath"
Write-Host "============================="
Write-Host "執行 publish-news.bat 套用至網站。"
