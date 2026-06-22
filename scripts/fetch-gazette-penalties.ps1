#Requires -Version 5.1
<#
.SYNOPSIS
  從行政院公報「處分」類公告抓取醫療衛生機構行政裁處，寫入 data/review-queue.json。

.DESCRIPTION
  資料來源：行政院公報資訊網 advancedSearchResult（styleL=5 處分類）
    https://gazette.nat.gov.tw/egFront/advancedSearchResult.do?action=doQuery&styleL=5

  作法：
    1. 以 Invoke-WebRequest + Session Cookie 維持查詢狀態
    2. 用 pubdateStart/pubdateEnd 限制最近 N 天，減少頁數
    3. 逐頁抓取 10 筆/頁，過濾含「衛生|健保|醫療|診所|治療|醫師|護理|藥局」的公告
    4. 符合條件者再抓 detail 頁，與 therapy-institutions.json + institutions.json 比對機構名稱
    5. 有命中者寫入 review-queue.json（status="pending"，需人工確認）

  已處理 MetaId 記錄於 data/gazette-seen.json，避免重複。
  中央行政院公報衛生相關處分較少（約每月 1-2 筆）；此腳本主要作為長期補充。

.PARAMETER Root
  專案根目錄，預設為本腳本上層目錄。

.PARAMETER DelayMs
  HTTP 請求間隔毫秒。預設 2000。

.PARAMETER LookbackDays
  往回查幾天的公報。預設 30。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\fetch-gazette-penalties.ps1
  powershell -ExecutionPolicy Bypass -File .\scripts\fetch-gazette-penalties.ps1 -LookbackDays 90
#>
param(
  [string]$Root         = (Split-Path -Parent $PSScriptRoot),
  [int]$DelayMs         = 2000,
  [int]$LookbackDays    = 30
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.Web.Extensions

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
  Add-Type -TypeDefinition @"
using System.Net; using System.Net.Security; using System.Security.Cryptography.X509Certificates;
public class GazSslBypass {
  public static void Trust() {
    ServicePointManager.ServerCertificateValidationCallback =
      (object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) => true;
  }
}
"@
  [GazSslBypass]::Trust()
} catch {}

# ---------------------------------------------------------------------------
# 工具函式
# ---------------------------------------------------------------------------

function ConvertTo-Slug([string]$Text) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $sha   = [System.Security.Cryptography.SHA256]::Create()
  (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 16)
}

function ConvertTo-CleanDict($Item) {
  if ($Item -is [System.Collections.IDictionary]) {
    $d = [ordered]@{}
    foreach ($k in $Item.Keys) {
      $v = $Item[$k]
      if ($v -is [System.Collections.IList] -and $v -isnot [string]) {
        $d[$k] = @($v | ForEach-Object { ConvertTo-CleanDict $_ })
      } elseif ($v -is [System.Collections.IDictionary]) {
        $d[$k] = ConvertTo-CleanDict $v
      } else {
        $d[$k] = $v
      }
    }
    return $d
  }
  return $Item
}

function Read-JsonArrayFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $raw = $raw.TrimStart([char]0xFEFF)
  if ($raw.StartsWith("ï»¿")) { $raw = $raw.Substring(3) }
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  $ser.MaxJsonLength = 268435456
  try {
    $items = $ser.DeserializeObject($raw)
  } catch {
    Write-Warning "Read-JsonArrayFile: invalid JSON in '$Path' — $($_.Exception.Message)"
    return @()
  }
  if ($null -eq $items) { return @() }
  return @($items | ForEach-Object { ConvertTo-CleanDict $_ })
}

function Write-JsonArrayFile([string]$Path, $Array) {
  $json = $Array | ConvertTo-Json -Depth 6 -Compress
  if ($null -eq $json) { $json = "[]" }
  if ($json -notmatch '^\[') { $json = "[$json]" }
  [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
}

function ConvertTo-PlainText([string]$Html) {
  if (-not $Html) { return "" }
  $Html = $Html -replace '<br\s*/?>', "`n"
  $Html = $Html -replace '</p>', "`n"
  $Html = $Html -replace '<[^>]+>',''
  $Html = [System.Net.WebUtility]::HtmlDecode($Html)
  $Html = $Html.Trim()
  return $Html
}

# ---------------------------------------------------------------------------
# 主程序
# ---------------------------------------------------------------------------

$dataDir = Join-Path $Root "data"
Write-Host "=== 兒少防火牆：行政院公報醫療裁處（styleL=5 處分 HTML 爬取）==="

# 載入機構名稱查詢表
$instLookup = [System.Collections.Generic.Dictionary[string,object]]::new()

$therapyPath = Join-Path $dataDir "therapy-institutions.json"
if (Test-Path -LiteralPath $therapyPath) {
  foreach ($inst in @(Read-JsonArrayFile $therapyPath)) {
    $n = "$($inst["name"])".Trim()
    if ($n.Length -ge 4 -and -not $instLookup.ContainsKey($n)) { $instLookup[$n] = $inst }
  }
  Write-Host "治療機構：$($instLookup.Count) 筆"
}

$instsPath = Join-Path $dataDir "institutions.json"
if (Test-Path -LiteralPath $instsPath) {
  $before = $instLookup.Count
  foreach ($inst in @(Read-JsonArrayFile $instsPath)) {
    $n = "$($inst["name"])".Trim()
    if ($n.Length -ge 4 -and -not $instLookup.ContainsKey($n)) { $instLookup[$n] = $inst }
  }
  Write-Host "教育機構加入：$($instLookup.Count - $before) 筆"
}
Write-Host "查詢表總計：$($instLookup.Count) 筆"
Write-Host ""

# 載入已處理的 MetaId
$seenPath  = Join-Path $dataDir "gazette-seen.json"
$seenItems = @(Read-JsonArrayFile $seenPath)
$seenIds   = [System.Collections.Generic.HashSet[string]]::new()
foreach ($s in $seenItems) { [void]$seenIds.Add("$($s["id"])") }

# 載入 review-queue
$queuePath = Join-Path $dataDir "review-queue.json"
$queue     = [System.Collections.ArrayList]::new(@(Read-JsonArrayFile $queuePath))
$queueIds  = [System.Collections.Generic.HashSet[string]]::new()
foreach ($q in $queue) { [void]$queueIds.Add("$($q["id"])") }

# ---------------------------------------------------------------------------
# 爬取行政院公報處分類（styleL=5），含機構名稱關鍵詞過濾
# ---------------------------------------------------------------------------

$BASE = "https://gazette.nat.gov.tw/egFront"
$startDate = (Get-Date).AddDays(-$LookbackDays).ToString("yyyy-MM-dd")
$endDate   = (Get-Date).ToString("yyyy-MM-dd")

Write-Host "查詢期間：$startDate ~ $endDate"

$ua        = "Mozilla/5.0 (compatible; KidsSafetyWall/1.0)"
$session   = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$addedCount = 0
$newSeenItems = [System.Collections.ArrayList]::new()

# 關鍵詞過濾：必須包含衛生相關或醫療相關字眼
$HEALTH_PATTERN = "衛生局|衛生福利部|健保|衛生所|醫療|醫院|診所|治療所|藥局|醫師|護理|照護"

try {
  # 第一頁（建立 Session）
  $firstUrl = "$BASE/advancedSearchResult.do?action=doQuery&styleL=5&pubdateStart=$startDate&pubdateEnd=$endDate"
  Write-Host "初始查詢：$firstUrl"
  $resp = Invoke-WebRequest -Uri $firstUrl -WebSession $session -UseBasicParsing -UserAgent $ua -TimeoutSec 30
  $totalMatch = [regex]::Match($resp.Content, '共(\d+)[筆條]')
  $total = if ($totalMatch.Success) { [int]$totalMatch.Groups[1].Value } else { 0 }
  Write-Host "找到 $total 筆處分公告（限此期間）"

  $pageNum = 1
  $pageContent = $resp.Content

  while ($true) {
    Write-Host "  第 $pageNum 頁..."

    # 從頁面提取條目清單（metaid + title）
    # title 出現在 PDF 預覽按鈕的 title 屬性中，格式：title="公告標題(另開視窗顯示PDF)"
    $entryPattern = 'metaid=(\d+)[^"]*"[^>]*>[\s\S]{0,2000}?title="([^"(]+)(?:\([^)]*\))?"'
    $entries = [regex]::Matches($pageContent, $entryPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

    foreach ($entry in $entries) {
      $metaId = $entry.Groups[1].Value
      $rawTitle = $entry.Groups[2].Value.Trim()

      # 先以標題關鍵詞快速過濾（健保/衛生/醫療相關）
      if ($rawTitle -notmatch $HEALTH_PATTERN) { continue }

      # 已處理過的略過
      $seenKey = "gazette-$metaId"
      if ($seenIds.Contains($seenKey)) { continue }
      [void]$newSeenItems.Add([ordered]@{ id = $seenKey })
      [void]$seenIds.Add($seenKey)

      Write-Host "    ★ 衛生相關：metaid=$metaId | $($rawTitle.Substring(0,[Math]::Min(80,$rawTitle.Length)))"

      # 抓取 detail 頁取得完整內容
      Start-Sleep -Milliseconds ([Math]::Max(500, $DelayMs / 2))
      $detailContent = ""
      $detailTitle   = $rawTitle
      $pubDate       = ""
      $agency        = ""
      try {
        $dr = Invoke-WebRequest -Uri "$BASE/detail.do?metaid=$metaId&log=detailLog" -WebSession $session -UseBasicParsing -UserAgent $ua -TimeoutSec 20
        $detailContent = $dr.Content

        # 嘗試抓取標題（og:title 或 page title）
        $ogTitle = [regex]::Match($detailContent, '<meta[^>]*property="og:title"[^>]*content="([^"]+)"')
        if ($ogTitle.Success) { $detailTitle = $ogTitle.Groups[1].Value -replace ' \|.*','' }
        else {
          $pgTitle = [regex]::Match($detailContent, '<title>行政院公報資訊網 \| ([^<]+)</title>')
          if ($pgTitle.Success) { $detailTitle = $pgTitle.Groups[1].Value }
        }

        # 抓取日期
        $dateMatch = [regex]::Match($detailContent, '中華民國(\d+)年(\d+)月(\d+)日')
        if ($dateMatch.Success) {
          $rocY = [int]$dateMatch.Groups[1].Value
          $mm   = $dateMatch.Groups[2].Value.PadLeft(2,'0')
          $dd   = $dateMatch.Groups[3].Value.PadLeft(2,'0')
          $pubDate = "$($rocY + 1911)-$mm-$dd"
        }

        # 抓取機關名稱
        $agencyMatch = [regex]::Match($detailContent, '(?:發布機關|機\s*關)[^：:]*[：:][\s]*([^\n<]{2,30})')
        if ($agencyMatch.Success) { $agency = $agencyMatch.Groups[1].Value.Trim() }
      } catch {
        Write-Warning "    detail 頁下載失敗：$($_.Exception.Message)"
      }

      # 嘗試比對機構名稱
      $combinedText = "$detailTitle $detailContent"
      $matchedInst  = $null
      $matchedName  = ""
      foreach ($instName in $instLookup.Keys) {
        if ($combinedText.Contains($instName)) {
          $matchedInst = $instLookup[$instName]
          $matchedName = $instName
          break
        }
      }

      # 有具體機構命中才寫入；否則僅記錄為 seen（避免每次重複抓取）
      if (-not $matchedInst) {
        Write-Host "    （未命中已知機構名稱，略過）"
        continue
      }

      $eventId = "gazette-meta-$metaId"
      if ($queueIds.Contains($eventId)) { continue }

      $shortContent = ConvertTo-PlainText $detailContent
      if ($shortContent.Length -gt 300) { $shortContent = $shortContent.Substring(0, 300) + "…" }

      [void]$queue.Add([ordered]@{
        id          = $eventId
        type        = "gazette-penalty"
        title       = $detailTitle
        date        = if ($pubDate) { $pubDate } else { (Get-Date).ToString("yyyy-MM-dd") }
        url         = "$BASE/detail.do?metaid=$metaId"
        source      = "行政院公報"
        agency      = $agency
        institution = [ordered]@{
          key  = "$($matchedInst["key"])"
          name = $matchedName
          type = "$($matchedInst["type"])"
          city = "$($matchedInst["city"])"
        }
        summary     = $shortContent
        status      = "pending"
        createdAt   = (Get-Date).ToString("yyyy-MM-dd")
      })
      [void]$queueIds.Add($eventId)
      $addedCount++
      Write-Host "    ✓ 新增事件：$matchedName"
    }

    # 下一頁
    if ($pageContent -notmatch "pageNum=$($pageNum + 1)") { break }
    $pageNum++
    if ($pageNum -gt 50) { Write-Warning "超過 50 頁，停止（可能有問題）"; break }
    Start-Sleep -Milliseconds $DelayMs
    try {
      $resp = Invoke-WebRequest -Uri "$BASE/advancedSearchResult.do?action=doChangePage&pageNum=$pageNum" -WebSession $session -UseBasicParsing -UserAgent $ua -TimeoutSec 30
      $pageContent = $resp.Content
    } catch {
      Write-Warning "第 $pageNum 頁下載失敗：$($_.Exception.Message)"
      break
    }
  }
} catch {
  Write-Warning "查詢失敗：$($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 儲存結果
# ---------------------------------------------------------------------------

Write-JsonArrayFile $queuePath @($queue)
Write-Host ""
Write-Host "review-queue.json 共 $($queue.Count) 筆"

$allSeen = @($seenItems) + @($newSeenItems)
Write-JsonArrayFile $seenPath $allSeen
Write-Host "gazette-seen.json 已記錄 $($allSeen.Count) 個 MetaId"
Write-Host ""
Write-Host "完成：本次新增 $addedCount 筆行政院公報醫療裁處事件"
