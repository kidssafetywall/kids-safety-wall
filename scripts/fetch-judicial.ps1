#Requires -Version 5.1
<#
.SYNOPSIS
  從司法院裁判書開放 API 搜尋含教育機構名稱的裁判書，寫入 data/review-queue.json。

.DESCRIPTION
  API 端點：https://data.judicial.gov.tw/jdg/api/SearchResult
  參數：kw（關鍵字）、PN（頁碼，從 1 起）、count（每頁筆數，上限 20）
  回傳：JSON，含 jud[]、totalCount
  不需 API 金鑰，公開存取。

.PARAMETER Root
  專案根目錄，預設為本腳本上層目錄。

.PARAMETER MaxNewPerRun
  單次執行最多新增幾筆事件。預設 40。

.PARAMETER DelayMs
  每次 API 呼叫之間的等待毫秒。預設 1500。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\fetch-judicial.ps1
#>
param(
  [string]$Root       = (Split-Path -Parent $PSScriptRoot),
  [int]$MaxNewPerRun  = 40,
  [int]$DelayMs       = 1500
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Web.Extensions

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
  try {
    $items = $serializer.DeserializeObject($raw)
  } catch {
    Write-Warning "Read-JsonArrayFile: invalid JSON in '$Path' — $($_.Exception.Message)"
    return @()
  }
  if ($null -eq $items) { return @() }
  return @($items)
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

# ---------------------------------------------------------------------------
# 呼叫司法院 API，回傳裁判書陣列
# ---------------------------------------------------------------------------

function Invoke-JudicialSearch([string]$Keyword, [int]$Page = 1) {
  # 使用 FJUD（法院全球資訊網）關鍵字搜尋，解析 HTML 回傳的判決清單
  $encoded = [System.Uri]::EscapeDataString($Keyword)
  $url     = "https://judgment.judicial.gov.tw/FJUD/default.aspx?q=$encoded&page=$Page"
  try {
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -Headers @{
      "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
      "Accept"     = "text/html,application/xhtml+xml"
      "Referer"    = "https://judgment.judicial.gov.tw/FJUD/default.aspx"
    }
    $html  = $resp.Content
    $items = [System.Collections.ArrayList]::new()

    # 解析判決列表（每筆 <li class="col-*"> 或 <tr> 含判決資訊）
    # FJUD 結果格式：案號、日期、案由、全文連結
    $rowPattern = '(?is)<tr[^>]*>\s*<td[^>]*>\s*<a[^>]+href="([^"]+)"[^>]*>([^<]+)</a>\s*</td>\s*<td[^>]*>([^<]*)</td>\s*<td[^>]*>([^<]*)</td>'
    $rowMatches = [regex]::Matches($html, $rowPattern)

    if ($rowMatches.Count -eq 0) {
      # 備用格式：抓所有裁判字號連結
      $linkPattern = '(?is)<a[^>]+href="(/FJUD/data\.aspx\?[^"]+)"[^>]*>\s*([0-9A-Za-z一-鿿，]+裁?\d*[字第號]?\d*)\s*</a>'
      $linkMatches  = [regex]::Matches($html, $linkPattern)
      foreach ($m in $linkMatches) {
        $judUrl = "https://judgment.judicial.gov.tw" + $m.Groups[1].Value
        [void]$items.Add(@{
          JNUM = Strip-Html $m.Groups[2].Value
          JID  = $judUrl
        })
      }
    } else {
      foreach ($m in $rowMatches) {
        $relUrl = $m.Groups[1].Value
        $judUrl = if ($relUrl.StartsWith("http")) { $relUrl } else { "https://judgment.judicial.gov.tw$relUrl" }
        [void]$items.Add(@{
          JNUM  = Strip-Html $m.Groups[2].Value
          JDATE = Strip-Html $m.Groups[3].Value
          JCASE = Strip-Html $m.Groups[4].Value
          JID   = $judUrl
        })
      }
    }

    return @{ items = @($items); totalCount = $items.Count }
  } catch {
    Write-Warning "FJUD 查詢失敗 (kw=$Keyword, page=$Page)：$($_.Exception.Message)"
    return @{ items = @(); totalCount = 0 }
  }
}

# ---------------------------------------------------------------------------
# 從裁判書資料解析欄位（API 欄位名稱依司法院文件）
# ---------------------------------------------------------------------------

function Get-JudField($Jud, [string[]]$Keys) {
  foreach ($key in $Keys) {
    if ($Jud.ContainsKey($key) -and $null -ne $Jud[$key] -and "$($Jud[$key])" -ne "") {
      return "$($Jud[$key])"
    }
  }
  return ""
}

function Build-JudicialUrl($Jud) {
  # 優先取 API 回傳的 JID（裁判書全文連結）
  $jid = Get-JudField $Jud @("JID", "jid", "JFULL", "jfull")
  if ($jid -and $jid.StartsWith("http")) { return $jid }
  # 用案號組合司法院全文查詢 URL
  $jnum = Get-JudField $Jud @("JNUM", "jnum", "案號", "caseNo")
  if ($jnum) {
    $encoded = [System.Uri]::EscapeDataString($jnum)
    return "https://judgment.judicial.gov.tw/FJUD/qrynormaljudgment.aspx?jno=$encoded"
  }
  return ""
}

# ---------------------------------------------------------------------------
# 路徑設定
# ---------------------------------------------------------------------------

$dataDir    = Join-Path $Root "data"
$archiveDir = Join-Path $Root "archive"
$rawDir     = Join-Path $archiveDir "raw"
Ensure-Directory $rawDir

$seenPath   = Join-Path $dataDir "judicial-seen.json"
$queuePath  = Join-Path $dataDir "review-queue.json"
$eventsPath = Join-Path $dataDir "events.json"

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

# ---------------------------------------------------------------------------
# 建立查詢關鍵字清單
# ---------------------------------------------------------------------------

# 通用教育機構關鍵字（補充已知機構以外的新案件）
$generalKeywords = @(
  @{ kw = "幼兒園";       type = "幼兒園";       name = "待人工分類" },
  @{ kw = "補習班";       type = "補習班";       name = "待人工分類" },
  @{ kw = "課後照顧中心"; type = "課後照顧中心"; name = "待人工分類" },
  @{ kw = "兒童虐待";     type = "（教育相關）"; name = "待人工分類" },
  @{ kw = "校園霸凌";     type = "（教育相關）"; name = "待人工分類" }
)

# 已知機構（針對性監控）；排除 government_dataset 來源的假機構條目
$knownInstitutions = [ordered]@{}
foreach ($item in ($existingEvents + $existingQueue)) {
  $category = "$($item["category"])"
  if ($category -eq "government_dataset") { continue }
  $inst = $item["institution"]
  if (-not $inst) { continue }
  $name = "$($inst["name"])"
  if (-not $name -or $name -eq "待人工分類") { continue }
  if ($name -match "資料源$") { continue }
  if (-not $knownInstitutions.Contains($name)) {
    $knownInstitutions[$name] = [ordered]@{
      name = $name
      type = "$($inst["type"])"
      city = "$($inst["city"])"
    }
  }
}

$allQueries = [System.Collections.ArrayList]::new()
foreach ($gq in $generalKeywords) { [void]$allQueries.Add($gq) }
foreach ($inst in $knownInstitutions.Values) {
  [void]$allQueries.Add([ordered]@{
    kw       = $inst.name
    type     = $inst.type
    name     = $inst.name
    city     = $inst.city
    specific = $true
  })
}

Write-Host "=== 兒少防火牆：司法裁判書抓取 ==="
Write-Host "通用查詢：$($generalKeywords.Count) 筆  專項查詢：$($knownInstitutions.Count) 筆  上限：$MaxNewPerRun 筆"

# ---------------------------------------------------------------------------
# 查詢 API 並處理結果
# ---------------------------------------------------------------------------

$newEvents = [System.Collections.ArrayList]::new()
$totalNew  = 0

foreach ($entry in $allQueries) {
  if ($totalNew -ge $MaxNewPerRun) {
    Write-Host "已達本次上限，停止查詢。"
    break
  }

  Write-Host "`n[查詢] $($entry.kw)"
  $result = Invoke-JudicialSearch -Keyword $entry.kw -Page 1
  Write-Host "  取得 $($result.items.Count) 筆"

  foreach ($jud in $result.items) {
    if ($totalNew -ge $MaxNewPerRun) { break }

    # 取案號作為去重鍵
    $caseNo = Get-JudField $jud @("JNUM", "jnum", "案號", "caseNo", "JID", "jid")
    if (-not $caseNo) { continue }
    if ($seenSet.Contains($caseNo)) { continue }

    # 解析欄位
    $court    = Get-JudField $jud @("JTITLE", "jtitle", "法院", "court", "COURT")
    $caseType = Get-JudField $jud @("JCASE", "jcase", "案由", "caseType", "JTYPE", "jtype")
    $judDate  = Get-JudField $jud @("JDATE", "jdate", "裁判日期", "judgeDate")
    $abstract = Get-JudField $jud @("JABSTRACT", "jabstract", "摘要", "abstract", "SUMMARY")

    # 標準化日期（民國 → 西元，或直接解析）
    $eventDate = "unknown"
    if ($judDate) {
      if ($judDate -match '^(\d{3})/(\d{2})/(\d{2})$') {
        $eventDate = "$([int]$Matches[1] + 1911)-$($Matches[2])-$($Matches[3])"
      } elseif ($judDate -match '^\d{4}-\d{2}-\d{2}$') {
        $eventDate = $judDate
      } else {
        try { $eventDate = [datetime]::Parse($judDate).ToString("yyyy-MM-dd") } catch {}
      }
    }

    # 摘要截斷
    $summary = $abstract
    if (-not $summary) { $summary = "$court $caseType $caseNo" }
    if ($summary.Length -gt 300) { $summary = $summary.Substring(0, 300) + "…" }

    # 裁判書全文 URL
    $judUrl = Build-JudicialUrl $jud
    if (-not $judUrl) {
      Write-Warning "  無法取得全文 URL，跳過案號 $caseNo"
      [void]$seenSet.Add($caseNo)
      continue
    }

    # 快照封存
    Write-Host "  + 封存：$court $caseNo ($eventDate)"
    $capture = Get-PageSnapshot -Url $judUrl -ArchiveDir $rawDir -Prefix "judicial"

    $eventId    = "judicial-$(ConvertTo-Slug $caseNo)"
    $importedAt = (Get-Date).ToUniversalTime().ToString("o")
    $instCity   = if ($entry.ContainsKey("city") -and $entry.city) { $entry.city } else { "" }

    $title = if ($court -and $caseType) { "$court $caseType" } elseif ($court) { "$court $caseNo" } else { "司法裁判書 $caseNo" }

    $newEvent = [ordered]@{
      id                 = $eventId
      verificationStatus = "pending"
      autoImported       = $true
      importSource       = "judicial-api"
      searchQuery        = $entry.kw
      caseNo             = $caseNo
      institution        = [ordered]@{
        name     = $entry.name
        type     = $entry.type
        city     = $instCity
        district = ""
        address  = ""
        code     = ""
        aliases  = @()
      }
      risk               = "mid"
      category           = "judicial"
      title              = $title
      summary            = $summary
      eventDate          = $eventDate
      importedAt         = $importedAt
      tags               = @("自動匯入", "司法裁判書", $entry.type)
      evidence           = @(
        [ordered]@{
          title        = "$court $caseNo"
          publisher    = "司法院"
          url          = $judUrl
          type         = "judicial"
          capturedAt   = $capture.capturedAt
          snapshotPath = $capture.snapshotPath
          httpStatus   = $capture.httpStatus
          status       = $capture.captureStatus
        }
      )
    }

    [void]$newEvents.Add($newEvent)
    [void]$seenSet.Add($caseNo)
    $totalNew++
  }

  Start-Sleep -Milliseconds $DelayMs
}

# ---------------------------------------------------------------------------
# 寫回檔案
# ---------------------------------------------------------------------------

if ($newEvents.Count -gt 0) {
  $merged     = @($existingQueue) + @($newEvents)
  $prettyJson = $merged | ConvertTo-Json -Depth 18
  [System.IO.File]::WriteAllText($queuePath, $prettyJson, [System.Text.Encoding]::UTF8)
  Write-Host "`n已新增 $($newEvents.Count) 筆司法裁判書事件至 $queuePath"
} else {
  Write-Host "`n沒有新裁判書事件。"
}

$seenOutput = [ordered]@{
  updatedAt = (Get-Date).ToUniversalTime().ToString("o")
  seen      = @($seenSet)
}
[System.IO.File]::WriteAllText($seenPath, ($seenOutput | ConvertTo-Json -Depth 4), [System.Text.Encoding]::UTF8)
Write-Host "已更新 $seenPath（已知案號：$($seenSet.Count) 筆）"
