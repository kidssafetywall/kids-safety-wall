#Requires -Version 5.1
<#
.SYNOPSIS
  從教育部政府開放資料抓取幼兒園裁處案件，寫入 data/events.json（已查證）或 data/review-queue.json（待審）。

.DESCRIPTION
  資料來源（由腳本自動探查，有 JSON 資源直接下載，否則解析 HTML 表格）：

    1. 教育部幼兒教育及照顧資訊網 — 違規幼兒園裁處案件
       https://data.gov.tw/dataset/6258
       若政府開放平台有 JSON 資源 → 直接匯入（verified）
       若無 → 嘗試解析 HTML 表格（pending）

    2. 全國補習班違規資料 — 以教育部補習班立案查詢系統為輔助來源
       此來源目前為 HTML，解析後置入 review-queue（pending）

  高確信度（政府 JSON）→ events.json（verified）
  低確信度（HTML 解析）→ review-queue.json（pending）

.PARAMETER Root
  專案根目錄，預設為本腳本上層目錄。

.PARAMETER DelayMs
  每次 HTTP 請求之間的等待毫秒。預設 2000。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\fetch-penalties.ps1
#>
param(
  [string]$Root    = (Split-Path -Parent $PSScriptRoot),
  [int]$DelayMs    = 2000
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.Web.Extensions

# PowerShell 5.1 SSL 略過（部分政府網站憑證鏈不完整）
[Net.ServicePointManager]::SecurityProtocol = `
  [Net.SecurityProtocolType]::Tls -bor `
  [Net.SecurityProtocolType]::Tls11 -bor `
  [Net.SecurityProtocolType]::Tls12
try {
  Add-Type -TypeDefinition @"
using System.Net; using System.Net.Security; using System.Security.Cryptography.X509Certificates;
public class SslBypass {
  public static void Trust() {
    ServicePointManager.ServerCertificateValidationCallback =
      (object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) => true;
  }
}
"@
  [SslBypass]::Trust()
} catch {}  # 若已加入型別則略過

# ---------------------------------------------------------------------------
# 共用工具函式
# ---------------------------------------------------------------------------

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function ConvertTo-Slug([string]$Text) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $sha   = [System.Security.Cryptography.SHA256]::Create()
  (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 16)
}

function Read-JsonArrayFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $raw = $raw.TrimStart([char]0xFEFF)
  if ($raw.StartsWith("ï»¿")) { $raw = $raw.Substring(3) }
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  $serializer.MaxJsonLength = 67108864
  $items = $serializer.DeserializeObject($raw)
  if ($null -eq $items) { return @() }
  return @($items)
}

function Strip-Html([string]$Html) {
  if (-not $Html) { return "" }
  $text = $Html -replace '<[^>]+>', ' '
  $text = [System.Web.HttpUtility]::HtmlDecode($text)
  $text = $text -replace '\s+', ' '
  return $text.Trim()
}

function Get-PageSnapshot([string]$Url, [string]$ArchiveDir, [string]$Prefix) {
  $id         = ConvertTo-Slug $Url
  $file       = Join-Path $ArchiveDir "$Prefix-$id.html"
  $capturedAt = (Get-Date).ToUniversalTime().ToString("o")
  try {
    $headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36" }
    $resp    = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -Headers $headers
    $comment = "<!--`nsource: $Url`ncaptured_at_utc: $capturedAt`nstatus_code: $($resp.StatusCode)`n-->`n"
    [System.IO.File]::WriteAllText($file, $comment + $resp.Content, [System.Text.Encoding]::UTF8)
    return @{
      capturedAt    = $capturedAt
      snapshotPath  = ($file.Replace($Root, "").TrimStart("\") -replace "\\", "/")
      httpStatus    = $resp.StatusCode
      captureStatus = "captured"
    }
  } catch {
    $msg = $_.Exception.Message
    if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) }
    return @{
      capturedAt    = $capturedAt
      snapshotPath  = $null
      httpStatus    = $null
      captureStatus = "capture_failed: $msg"
    }
  }
}

function Normalize-RocDate([string]$Value) {
  # 民國年 YYY/MM/DD 或 YYYMMDD → 西元 YYYY-MM-DD
  if ($Value -match '^(\d{2,3})/(\d{1,2})/(\d{1,2})$') {
    $y = [int]$Matches[1] + 1911
    return "$y-$($Matches[2].PadLeft(2,'0'))-$($Matches[3].PadLeft(2,'0'))"
  }
  if ($Value -match '^(\d{3})(\d{2})(\d{2})$') {
    $y = [int]$Matches[1] + 1911
    return "$y-$($Matches[2])-$($Matches[3])"
  }
  if ($Value -match '^\d{4}-\d{2}-\d{2}$') { return $Value }
  return "unknown"
}

function Get-Prop($Item, [string[]]$Keys) {
  foreach ($key in $Keys) {
    if ($Item.ContainsKey($key) -and $null -ne $Item[$key] -and "$($Item[$key])" -ne "") {
      return "$($Item[$key])"
    }
  }
  return ""
}

# 從政府資料平台頁面 HTML 找最新 JSON 資源下載 URL
function Get-LatestJsonResourceUrl([string]$Html) {
  $matches = [regex]::Matches($Html, '"contentUrl"\s*:\s*"([^"]+\.json)"')
  if ($matches.Count -eq 0) { return $null }
  return $matches[$matches.Count - 1].Groups[1].Value.Replace("\/", "/")
}

# 解析 HTML 表格，回傳 rows（每列為 @{欄名→值} 的 hashtable）
function Parse-HtmlTable([string]$Html) {
  $rows    = [System.Collections.ArrayList]::new()
  $headers = @()

  # 找第一個 <table>
  $tableMatch = [regex]::Match($Html, '(?is)<table[^>]*>(.*?)</table>')
  if (-not $tableMatch.Success) { return @() }
  $tableHtml = $tableMatch.Groups[1].Value

  # 取標題列
  $theadMatch = [regex]::Match($tableHtml, '(?is)<thead[^>]*>(.*?)</thead>')
  $headerHtml = if ($theadMatch.Success) { $theadMatch.Groups[1].Value } else { "" }
  $thMatches  = [regex]::Matches($headerHtml, '(?is)<th[^>]*>(.*?)</th>')
  foreach ($th in $thMatches) { $headers += Strip-Html $th.Groups[1].Value }

  # 取資料列
  $trMatches = [regex]::Matches($tableHtml, '(?is)<tr[^>]*>(.*?)</tr>')
  foreach ($tr in $trMatches) {
    $tdMatches = [regex]::Matches($tr.Groups[1].Value, '(?is)<td[^>]*>(.*?)</td>')
    if ($tdMatches.Count -eq 0) { continue }
    $row = @{}
    for ($i = 0; $i -lt $tdMatches.Count; $i++) {
      $colName = if ($i -lt $headers.Count) { $headers[$i] } else { "col$i" }
      $row[$colName] = Strip-Html $tdMatches[$i].Groups[1].Value
    }
    [void]$rows.Add($row)
  }
  return @($rows)
}

# ---------------------------------------------------------------------------
# 路徑設定
# ---------------------------------------------------------------------------

$dataDir    = Join-Path $Root "data"
$archiveDir = Join-Path $Root "archive"
$rawDir     = Join-Path $archiveDir "raw"
$datasetDir = Join-Path $archiveDir "datasets"
Ensure-Directory $rawDir
Ensure-Directory $datasetDir

$seenPath    = Join-Path $dataDir "penalty-seen.json"
$queuePath   = Join-Path $dataDir "review-queue.json"
$eventsPath  = Join-Path $dataDir "events.json"

# ---------------------------------------------------------------------------
# 載入已知資料
# ---------------------------------------------------------------------------

$seenRaw = if (Test-Path -LiteralPath $seenPath) {
  Get-Content -LiteralPath $seenPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
  [pscustomobject]@{ updatedAt = ""; seen = @() }
}
$seenSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($seenRaw.seen))

$existingQueue  = Read-JsonArrayFile $queuePath
$existingEvents = Read-JsonArrayFile $eventsPath

$newVerified = [System.Collections.ArrayList]::new()
$newPending  = [System.Collections.ArrayList]::new()

# ---------------------------------------------------------------------------
# 來源 1：教育部幼兒園裁處案件（政府資料開放平台 dataset/6258）
# ---------------------------------------------------------------------------

$src1Url = "https://data.gov.tw/dataset/6258"
Write-Host "=== 兒少防火牆：裁罰公告抓取 ==="
Write-Host "`n[來源 1] 幼兒園裁處案件  $src1Url"

$capture1 = Get-PageSnapshot -Url $src1Url -ArchiveDir $rawDir -Prefix "penalty-moe-kg"
Start-Sleep -Milliseconds $DelayMs

if ($capture1.snapshotPath) {
  $pageHtml   = Get-Content -LiteralPath (Join-Path $Root $capture1.snapshotPath) -Raw -Encoding UTF8
  $jsonResUrl = Get-LatestJsonResourceUrl $pageHtml

  if ($jsonResUrl) {
    Write-Host "  找到 JSON 資源：$jsonResUrl"
    $resourcePath = Join-Path $datasetDir "penalty-moe-kg-$(ConvertTo-Slug $jsonResUrl).json"
    try {
      $client = New-Object System.Net.WebClient
      $bytes  = $client.DownloadData($jsonResUrl)
      [System.IO.File]::WriteAllBytes($resourcePath, $bytes)
      Write-Host "  下載完成：$resourcePath"

      $items = Read-JsonArrayFile $resourcePath
      Write-Host "  共 $($items.Count) 筆裁處記錄"

      foreach ($item in $items) {
        # 解析機構名稱（教育部資料欄位名稱可能因版本而異）
        $instName = Get-Prop $item @("機構名稱", "幼兒園名稱", "單位名稱", "name")
        if (-not $instName) { continue }

        $city    = Get-Prop $item @("縣市名稱", "縣市", "直轄市縣市別", "city")
        $penalty = Get-Prop $item @("裁罰事由", "違規事由", "處分事由", "裁處事由", "summary")
        $amount  = Get-Prop $item @("裁罰金額", "罰鍰金額", "金額", "penaltyAmount")
        $rawDate = Get-Prop $item @("裁罰日期", "處分日期", "裁處日期", "date")
        $law     = Get-Prop $item @("違反法令", "依據法令", "違反法條", "law")

        $eventDate = Normalize-RocDate $rawDate

        # 以「機構名稱 + 裁罰日期 + 金額」為去重鍵
        $dedupKey = ConvertTo-Slug "$instName|$eventDate|$amount"
        if ($seenSet.Contains($dedupKey)) { continue }

        $summary = $penalty
        if ($amount) { $summary += "（罰鍰 $amount 元）" }
        if ($law)    { $summary += "，違反：$law" }
        if ($summary.Length -gt 300) { $summary = $summary.Substring(0, 300) + "…" }

        $eventId    = "penalty-moe-kg-$(ConvertTo-Slug "$instName|$rawDate")"
        $importedAt = (Get-Date).ToUniversalTime().ToString("o")

        $event = [ordered]@{
          id                 = $eventId
          verificationStatus = "verified"
          autoImported       = $true
          importSource       = "penalty-gov-json"
          institution        = [ordered]@{
            name     = $instName
            type     = "幼兒園"
            city     = $city
            district = ""
            address  = Get-Prop $item @("地址", "學校地址", "address")
            code     = Get-Prop $item @("代碼", "機構代碼", "code")
            aliases  = @()
          }
          risk               = "high"
          category           = "penalty"
          title              = "主管機關裁罰：$instName"
          summary            = $summary
          eventDate          = $eventDate
          importedAt         = $importedAt
          tags               = @("政府裁罰", "幼兒園", "已查證")
          evidence           = @(
            [ordered]@{
              title        = "幼兒園裁處案件（教育部政府開放資料）"
              publisher    = "教育部"
              url          = $jsonResUrl
              type         = "government_doc"
              capturedAt   = $capture1.capturedAt
              snapshotPath = ("archive/datasets/penalty-moe-kg-$(ConvertTo-Slug $jsonResUrl).json")
              httpStatus   = 200
              status       = "captured"
            }
          )
        }

        [void]$newVerified.Add($event)
        [void]$seenSet.Add($dedupKey)
        Write-Host "  + 裁罰：$instName ($eventDate)"
      }
    } catch {
      Write-Warning "  無法下載 JSON 資源：$($_.Exception.Message)"
    }
  } else {
    Write-Host "  未找到 JSON 資源，改嘗試解析 HTML 表格…"
    $tableRows = Parse-HtmlTable $pageHtml
    Write-Host "  HTML 表格解析出 $($tableRows.Count) 列"

    foreach ($row in $tableRows) {
      $instName = Get-Prop $row @("機構名稱", "幼兒園名稱", "單位名稱")
      if (-not $instName) { continue }

      $rawDate  = Get-Prop $row @("裁罰日期", "處分日期", "日期")
      $eventDate = Normalize-RocDate $rawDate

      $dedupKey = ConvertTo-Slug "$instName|$eventDate"
      if ($seenSet.Contains($dedupKey)) { continue }

      $summary = Get-Prop $row @("裁罰事由", "違規事由", "事由", "說明")
      $amount  = Get-Prop $row @("罰鍰金額", "裁罰金額", "金額")
      if ($amount) { $summary += "（罰鍰 $amount 元）" }

      $eventId    = "penalty-moe-kg-html-$(ConvertTo-Slug "$instName|$rawDate")"
      $importedAt = (Get-Date).ToUniversalTime().ToString("o")
      $city       = Get-Prop $row @("縣市", "縣市名稱")

      $event = [ordered]@{
        id                 = $eventId
        verificationStatus = "pending"
        autoImported       = $true
        importSource       = "penalty-gov-html"
        institution        = [ordered]@{
          name = $instName; type = "幼兒園"; city = $city
          district = ""; address = ""; code = ""; aliases = @()
        }
        risk     = "high"
        category = "penalty"
        title    = "主管機關裁罰：$instName"
        summary  = $summary
        eventDate = $eventDate
        importedAt = $importedAt
        tags      = @("政府裁罰", "幼兒園", "HTML解析待驗證")
        evidence  = @(
          [ordered]@{
            title = "幼兒園裁處案件頁面"; publisher = "教育部"; url = $src1Url; type = "government_doc"
            capturedAt = $capture1.capturedAt; snapshotPath = $capture1.snapshotPath
            httpStatus = $capture1.httpStatus; status = $capture1.captureStatus
          }
        )
      }

      [void]$newPending.Add($event)
      [void]$seenSet.Add($dedupKey)
      Write-Host "  + HTML 裁罰（待審）：$instName ($eventDate)"
    }
  }
}

Start-Sleep -Milliseconds $DelayMs

# ---------------------------------------------------------------------------
# 來源 2：全國補習班違規（教育部補習班立案查詢系統，HTML 解析）
# ---------------------------------------------------------------------------

$src2Url = "https://bsb.edu.tw/bsbweb/violation_list.do"
Write-Host "`n[來源 2] 補習班違規  $src2Url"

try {
  $resp2   = Invoke-WebRequest -Uri $src2Url -UseBasicParsing -TimeoutSec 30 -Headers @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
  }
  $html2   = $resp2.Content
  $snap2Id = ConvertTo-Slug $src2Url
  $snap2   = Join-Path $rawDir "penalty-cram-school-$snap2Id.html"
  $snapAt2 = (Get-Date).ToUniversalTime().ToString("o")
  [System.IO.File]::WriteAllText($snap2, "<!--`nsource: $src2Url`ncaptured_at_utc: $snapAt2`n-->`n" + $html2, [System.Text.Encoding]::UTF8)
  $snapPath2 = ($snap2.Replace($Root, "").TrimStart("\") -replace "\\", "/")

  $tableRows2 = Parse-HtmlTable $html2
  Write-Host "  HTML 表格解析出 $($tableRows2.Count) 列"

  foreach ($row in $tableRows2) {
    $instName = Get-Prop $row @("補習班名稱", "班名", "機構名稱", "名稱")
    if (-not $instName) { continue }

    $rawDate  = Get-Prop $row @("違規日期", "處分日期", "裁罰日期", "日期")
    $eventDate = Normalize-RocDate $rawDate
    $city     = Get-Prop $row @("縣市", "縣市名稱", "直轄市縣市")

    $dedupKey = ConvertTo-Slug "$instName|$eventDate|cram"
    if ($seenSet.Contains($dedupKey)) { continue }

    $reason  = Get-Prop $row @("違規事由", "違規內容", "事由", "說明", "裁罰事由")
    $amount  = Get-Prop $row @("罰鍰金額", "裁罰金額", "金額")
    $summary = $reason
    if ($amount) { $summary += "（罰鍰 $amount 元）" }
    if (-not $summary) { $summary = "補習班違規裁罰" }

    $eventId    = "penalty-cram-$(ConvertTo-Slug "$instName|$rawDate")"
    $importedAt = (Get-Date).ToUniversalTime().ToString("o")

    $event = [ordered]@{
      id                 = $eventId
      verificationStatus = "pending"
      autoImported       = $true
      importSource       = "penalty-cram-html"
      institution        = [ordered]@{
        name = $instName; type = "補習班"; city = $city
        district = ""; address = ""; code = ""; aliases = @()
      }
      risk     = "high"
      category = "penalty"
      title    = "主管機關裁罰：$instName"
      summary  = $summary
      eventDate = $eventDate
      importedAt = $importedAt
      tags      = @("政府裁罰", "補習班", "HTML解析待驗證")
      evidence  = @(
        [ordered]@{
          title = "全國補習班違規名單"; publisher = "教育部"; url = $src2Url; type = "government_doc"
          capturedAt = $snapAt2; snapshotPath = $snapPath2; httpStatus = $resp2.StatusCode; status = "captured"
        }
      )
    }

    [void]$newPending.Add($event)
    [void]$seenSet.Add($dedupKey)
    Write-Host "  + 補習班違規（待審）：$instName ($eventDate)"
  }
} catch {
  Write-Warning "補習班違規來源抓取失敗：$($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 寫回檔案
# ---------------------------------------------------------------------------

Write-Host "`n=== 結果 ==="

# 已查證的裁罰 → events.json
if ($newVerified.Count -gt 0) {
  $mergedEvents = @($existingEvents) + @($newVerified)
  $eventsJson   = $mergedEvents | ConvertTo-Json -Depth 18
  [System.IO.File]::WriteAllText($eventsPath, $eventsJson, [System.Text.Encoding]::UTF8)
  Write-Host "已新增 $($newVerified.Count) 筆已查證裁罰至 $eventsPath"
}

# 待審的裁罰 → review-queue.json
if ($newPending.Count -gt 0) {
  $mergedQueue = @($existingQueue) + @($newPending)
  $queueJson   = $mergedQueue | ConvertTo-Json -Depth 18
  [System.IO.File]::WriteAllText($queuePath, $queueJson, [System.Text.Encoding]::UTF8)
  Write-Host "已新增 $($newPending.Count) 筆待審裁罰至 $queuePath"
}

if ($newVerified.Count -eq 0 -and $newPending.Count -eq 0) {
  Write-Host "沒有新裁罰資料。"
}

# 更新 penalty-seen.json
$seenOutput = [ordered]@{
  updatedAt = (Get-Date).ToUniversalTime().ToString("o")
  seen      = @($seenSet)
}
[System.IO.File]::WriteAllText($seenPath, ($seenOutput | ConvertTo-Json -Depth 4), [System.Text.Encoding]::UTF8)
Write-Host "已更新 $seenPath（已知去重鍵：$($seenSet.Count) 筆）"
