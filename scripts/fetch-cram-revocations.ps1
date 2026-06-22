#Requires -Version 5.1
<#
.SYNOPSIS
  從全國補習班資訊管理系統（bsb.kh.edu.tw）抓取廢止/註銷補習班，寫入 data/events.json（已查證）。

.DESCRIPTION
  資料來源：直轄市及各縣市短期補習班資訊管理系統
    https://bsb.kh.edu.tw/showpage.jsp?m=2
    教育部委高雄市維運，涵蓋全台 22 縣市
    廢止：主管機關強制撤銷立案（兒少安全高風險）
    註銷：業者自行申請撤銷（低風險，多為歇業）

  所有記錄來自政府官方系統 → events.json（verified，不需人工審核）

.PARAMETER Root
  專案根目錄，預設為本腳本上層目錄。

.PARAMETER MaxNewPerRun
  單次執行最多新增幾筆。0 = 不限（首次全量匯入）。預設 0。

.PARAMETER MaxPages
  最多抓幾頁（每頁 15 筆）。首次建議不設限；每日更新設 5 即可。預設 9999。

.PARAMETER DelayMs
  每頁請求間隔毫秒，預設 800。

.EXAMPLE
  # 首次全量匯入（約 17 分鐘）
  powershell -ExecutionPolicy Bypass -File .\scripts\fetch-cram-revocations.ps1

  # 每日增量更新（只抓最新 5 頁）
  powershell -ExecutionPolicy Bypass -File .\scripts\fetch-cram-revocations.ps1 -MaxPages 5
#>
param(
  [string]$Root           = (Split-Path -Parent $PSScriptRoot),
  [int]$MaxNewPerRun      = 0,
  [int]$MaxPages          = 9999,
  [int]$DelayMs           = 800,
  [switch]$IncrementalOnly    # 若設定：遇到整頁皆已知則立即停止（每日更新用）
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.Web.Extensions

[Net.ServicePointManager]::SecurityProtocol = `
  [Net.SecurityProtocolType]::Tls -bor `
  [Net.SecurityProtocolType]::Tls11 -bor `
  [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# 共用工具
# ---------------------------------------------------------------------------

function Initialize-Directory([string]$Path) {
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
  $s = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  $s.MaxJsonLength = 134217728
  try {
    $items = $s.DeserializeObject($raw)
  } catch {
    Write-Warning "Read-JsonArrayFile: invalid JSON in '$Path' — $($_.Exception.Message)"
    return @()
  }
  if ($null -eq $items) { return @() }
  return @($items)
}

function Write-JsonArrayFile([string]$Path, $Data) {
  $s = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  $s.MaxJsonLength = 134217728
  $json = $s.Serialize($Data)
  [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
}

function Convert-HtmlToText([string]$Html) {
  if (-not $Html) { return "" }
  $text = $Html -replace '<[^>]+>', ''
  $text = [System.Web.HttpUtility]::HtmlDecode($text)
  return $text.Trim()
}

function Format-City([string]$Value) {
  return "$Value".Replace("臺","台").Replace("　"," ").Trim()
}

# ---------------------------------------------------------------------------
# 路徑設定
# ---------------------------------------------------------------------------

$dataDir    = Join-Path $Root "data"
$archiveDir = Join-Path $Root "archive"
$rawDir     = Join-Path $archiveDir "raw"
Initialize-Directory $rawDir

$seenPath   = Join-Path $dataDir "cram-revoke-seen.json"
$eventsPath = Join-Path $dataDir "events.json"

# ---------------------------------------------------------------------------
# 載入已知紀錄
# ---------------------------------------------------------------------------

$seenRaw = if (Test-Path -LiteralPath $seenPath) {
  Get-Content -LiteralPath $seenPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
  [pscustomobject]@{ updatedAt = ""; seen = @() }
}
$seenSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($seenRaw.seen))

$existingEvents = Read-JsonArrayFile $eventsPath

Write-Host "=== 兒少防火牆：補習班廢止/註銷抓取 ==="
Write-Host "已知廢止記錄：$($seenSet.Count) 筆  現有事件：$($existingEvents.Count) 筆"
Write-Host "MaxNewPerRun=$(if($MaxNewPerRun -eq 0){'不限'}else{$MaxNewPerRun})  MaxPages=$MaxPages  DelayMs=$DelayMs ms"

# ---------------------------------------------------------------------------
# 逐頁抓取
# ---------------------------------------------------------------------------

$baseUrl   = "https://bsb.kh.edu.tw/showpage.jsp"
$headers   = @{
  "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
  "Referer"    = "https://bsb.kh.edu.tw/inquire.jsp?m=2"
  "Accept"     = "text/html,application/xhtml+xml,*/*"
}

$newEvents = [System.Collections.ArrayList]::new()
$totalNew  = 0
$pageNo    = 1
$stopFlag  = $false

while ($pageNo -le $MaxPages -and -not $stopFlag) {
  if ($MaxNewPerRun -gt 0 -and $totalNew -ge $MaxNewPerRun) {
    Write-Host "已達本次上限 ($MaxNewPerRun)，停止。"
    break
  }

  $url = "${baseUrl}?pageno=${pageNo}&l=0&p_name=&p_area=&p_road=&start_date=&end_date=&p_type=&c_type=&p_city=all&m=2"
  Write-Host "`n[頁 $pageNo] $url"

  try {
    $resp  = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -Headers $headers
    # 偵測編碼：部分縣市政府系統仍用 Big5
    $bytes = $resp.RawContentStream.ToArray()
    $head  = [System.Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(2000, $bytes.Length))
    $html  = if ($head -imatch 'charset\s*=\s*big5') {
      [System.Text.Encoding]::GetEncoding("big5").GetString($bytes)
    } else {
      [System.Text.Encoding]::UTF8.GetString($bytes)
    }
  } catch {
    Write-Warning "頁面取得失敗：$($_.Exception.Message)"
    Start-Sleep -Milliseconds ($DelayMs * 2)
    $pageNo++
    continue
  }

  # 解析 <tbody> 內的 <tr> 列
  $trMatches = [regex]::Matches($html, '(?s)<tr[^>]*>\s*(<td[^>]*>.*?</td>\s*){8,}\s*</tr>')
  if ($trMatches.Count -eq 0) {
    Write-Host "  無資料列，結束。"
    break
  }

  $newOnPage = 0
  foreach ($tr in $trMatches) {
    $tdMatches = [regex]::Matches($tr.Value, '(?s)<td[^>]*>(.*?)</td>')
    if ($tdMatches.Count -lt 9) { continue }

    $city       = Format-City (Convert-HtmlToText $tdMatches[1].Groups[1].Value)
    $name       = Convert-HtmlToText $tdMatches[2].Groups[1].Value
    $address    = Convert-HtmlToText $tdMatches[3].Groups[1].Value
    # td[4] = 電話（不儲存）
    $status     = Convert-HtmlToText $tdMatches[5].Groups[1].Value  # 廢止 or 註銷
    $docDate    = Convert-HtmlToText $tdMatches[6].Groups[1].Value  # 發文日期
    $docNumber  = Convert-HtmlToText $tdMatches[7].Groups[1].Value  # 文號
    $revokeDate = Convert-HtmlToText $tdMatches[8].Groups[1].Value  # 廢止/註銷日期

    if (-not $name -or -not $docNumber) { continue }

    # 去重
    $seenKey = ConvertTo-Slug $docNumber
    if ($seenSet.Contains($seenKey)) { continue }

    $newOnPage++
    [void]$seenSet.Add($seenKey)

    # 風險評級：廢止（主管機關強制）= 高；註銷（業者申請）= 低
    $risk = if ($status -eq "廢止") { "high" } else { "low" }

    $eventId    = "cram-revoke-$(ConvertTo-Slug $docNumber)"
    $importedAt = (Get-Date).ToUniversalTime().ToString("o")

    $title = "補習班${status}：${name}"
    $summary = "【$status】${name}（${city}）。文號：${docNumber}。發文日期：${docDate}。${status}日期：${revokeDate}。"

    $eventObj = [ordered]@{
      id                 = $eventId
      verificationStatus = "verified"
      autoImported       = $true
      importSource       = "bsb-cram-revocation"
      institution        = [ordered]@{
        name     = $name
        type     = "補習班"
        city     = $city
        district = ""
        address  = $address
        code     = ""
        aliases  = @()
      }
      risk               = $risk
      category           = "penalty"
      title              = $title
      summary            = $summary
      eventDate          = if ($revokeDate -match '^\d{4}-\d{2}-\d{2}$') { $revokeDate } else { $docDate }
      importedAt         = $importedAt
      penaltyDocNumber   = $docNumber
      penaltyContent     = "${status}立案"
      tags               = @("政府裁罰", "補習班", $status, "已查證")
      evidence           = @(
        [ordered]@{
          title        = "補習班${status}公告（全國補習班資訊管理系統）"
          publisher    = "教育部/各縣市政府教育局"
          url          = "https://bsb.kh.edu.tw/inquire.jsp?m=2"
          type         = "penalty"
          capturedAt   = $importedAt
          snapshotPath = $null
          httpStatus   = 200
          status       = "captured"
        }
      )
    }

    [void]$newEvents.Add($eventObj)
    $totalNew++
    Write-Host "  + $status $name（$city）$revokeDate"

    if ($MaxNewPerRun -gt 0 -and $totalNew -ge $MaxNewPerRun) {
      $stopFlag = $true
      break
    }
  }

  Write-Host "  本頁新增 $newOnPage 筆，累計 $totalNew 筆"

  # 每日增量模式：整頁皆已知則立刻停止（全量匯入模式不在此停，繼續往舊頁走）
  if ($newOnPage -eq 0 -and $IncrementalOnly) {
    Write-Host "第 $pageNo 頁全數已知，已追上最新紀錄，停止。"
    break
  }

  $pageNo++
  if ($pageNo -le $MaxPages -and -not $stopFlag) {
    Start-Sleep -Milliseconds $DelayMs
  }
}

# ---------------------------------------------------------------------------
# 寫回 events.json
# ---------------------------------------------------------------------------

if ($newEvents.Count -gt 0) {
  $merged = @($existingEvents) + @($newEvents)
  Write-JsonArrayFile $eventsPath $merged
  Write-Host "`n已新增 $($newEvents.Count) 筆廢止/註銷記錄至 $eventsPath（共 $($merged.Count) 筆）"
} else {
  Write-Host "`n沒有新記錄。"
}

# 更新 seen
$seenOutput = [ordered]@{
  updatedAt = (Get-Date).ToUniversalTime().ToString("o")
  seen      = @($seenSet)
}
$seenJson = ($seenOutput | ConvertTo-Json -Depth 4)
[System.IO.File]::WriteAllText($seenPath, $seenJson, [System.Text.Encoding]::UTF8)
Write-Host "已更新 $seenPath（已知：$($seenSet.Count) 筆）"
