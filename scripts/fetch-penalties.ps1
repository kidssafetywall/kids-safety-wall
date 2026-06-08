#Requires -Version 5.1
<#
.SYNOPSIS
  從教育部官方系統抓取幼兒園裁處案件，寫入 data/events.json（已查證）。

.DESCRIPTION
  資料來源：

    1. 教育部全國教保資訊網 — 裁罰紀錄查詢
       https://ap.ece.moe.edu.tw/webecems/punishSearch.aspx
       ASP.NET 表單（需兩步驟 GET+POST 取得 VIEWSTATE）
       政府官方公開資料 → 直接匯入為 verified（不需人工審核）

    2. 教育部幼兒園名錄（政府資料開放平台 dataset/6086）
       用於比對機構名稱，補充地址等資訊

  所有來自政府官方網站的裁罰紀錄 → events.json（verified，無需人工審核）

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

# TLS
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
} catch {}

# ---------------------------------------------------------------------------
# 共用工具
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

function Normalize-RocDate([string]$Value) {
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

function Get-LatestJsonResourceUrl([string]$Html) {
  $found = [regex]::Matches($Html, '"contentUrl"\s*:\s*"([^"]+\.json)"')
  if ($found.Count -eq 0) { return $null }
  return $found[$found.Count - 1].Groups[1].Value.Replace("\/", "/")
}

function Parse-HtmlTable([string]$Html) {
  $rows    = [System.Collections.ArrayList]::new()
  $headers = @()
  $tableMatch = [regex]::Match($Html, '(?is)<table[^>]*>(.*?)</table>')
  if (-not $tableMatch.Success) { return @() }
  $tableHtml = $tableMatch.Groups[1].Value
  $theadMatch = [regex]::Match($tableHtml, '(?is)<thead[^>]*>(.*?)</thead>')
  $headerHtml = if ($theadMatch.Success) { $theadMatch.Groups[1].Value } else { "" }
  $thMatches  = [regex]::Matches($headerHtml, '(?is)<th[^>]*>(.*?)</th>')
  foreach ($th in $thMatches) { $headers += Strip-Html $th.Groups[1].Value }
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

$seenPath   = Join-Path $dataDir "penalty-seen.json"
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
$existingEvents = Read-JsonArrayFile $eventsPath
$newVerified = [System.Collections.ArrayList]::new()

# ---------------------------------------------------------------------------
# 來源 1：教育部全國教保資訊網 — 裁罰紀錄查詢
#   URL: https://ap.ece.moe.edu.tw/webecems/punishSearch.aspx
#   須兩步驟：GET 取得 VIEWSTATE → POST 送出搜尋
#   所有記錄均為政府公開資料 → verified（無需人工審核）
# ---------------------------------------------------------------------------

$moeUrl = "https://ap.ece.moe.edu.tw/webecems/punishSearch.aspx"
Write-Host "=== 兒少防火牆：裁罰公告抓取 ==="
Write-Host "`n[來源 1] 教育部幼兒園裁罰紀錄  $moeUrl"

try {
  $headers = @{
    "User-Agent"      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    "Accept"          = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    "Accept-Language" = "zh-TW,zh;q=0.9,en;q=0.8"
  }

  # Step 1: GET 表單頁面，取得 VIEWSTATE 和 Session Cookie
  $session  = New-Object Microsoft.PowerShell.Commands.WebRequestSession
  $getResp  = Invoke-WebRequest -Uri $moeUrl -UseBasicParsing -TimeoutSec 30 `
                -Headers $headers -SessionVariable session
  $getHtml  = $getResp.Content
  Write-Host "  GET 表單成功（$($getHtml.Length) 位元組）"

  # 儲存快照
  $snapId   = ConvertTo-Slug $moeUrl
  $snapFile = Join-Path $rawDir "penalty-moe-kg-$snapId.html"
  $snapAt   = (Get-Date).ToUniversalTime().ToString("o")
  [System.IO.File]::WriteAllText($snapFile, "<!--`nsource: $moeUrl`ncaptured_at_utc: $snapAt`n-->`n" + $getHtml, [System.Text.Encoding]::UTF8)
  # $snapPath not used directly; POST result snapshot is captured below

  # 提取 VIEWSTATE、VIEWSTATEGENERATOR、EVENTVALIDATION
  $vsMatch   = [regex]::Match($getHtml, 'name="__VIEWSTATE"\s+id="__VIEWSTATE"\s+value="([^"]*)"')
  $vsgMatch  = [regex]::Match($getHtml, 'name="__VIEWSTATEGENERATOR"[^>]+value="([^"]*)"')
  $evMatch   = [regex]::Match($getHtml, 'name="__EVENTVALIDATION"[^>]+value="([^"]*)"')
  $viewState = $vsMatch.Groups[1].Value
  $vsGen     = $vsgMatch.Groups[1].Value
  $evVal     = $evMatch.Groups[1].Value
  Write-Host "  VIEWSTATE：$($viewState.Length)，VSGENERATOR：$vsGen，EVENTVALIDATION：$($evVal.Length)"

  if ($viewState.Length -lt 10) {
    Write-Warning "  無法提取 VIEWSTATE，跳過來源 1"
  } else {
    Start-Sleep -Milliseconds $DelayMs

    # Step 2: POST 送出空白搜尋（取得所有記錄）
    $postBody = @{
      "__VIEWSTATE"          = $viewState
      "__VIEWSTATEGENERATOR" = $vsGen
      "__VIEWSTATEENCRYPTED" = ""
      "__EVENTVALIDATION"    = $evVal
      "txtKeyNameS"          = ""
      "btnSearch"            = "搜尋"
    }
    $postHeaders = $headers.Clone()
    $postHeaders["Origin"]  = "https://ap.ece.moe.edu.tw"
    $postHeaders["Referer"] = $moeUrl

    $postResp = Invoke-WebRequest -Uri $moeUrl -Method POST -Body $postBody `
                  -UseBasicParsing -TimeoutSec 60 -WebSession $session `
                  -Headers $postHeaders
    $postHtml = $postResp.Content
    Write-Host "  POST 回應大小：$($postHtml.Length) 位元組"

    if ($postHtml.Length -gt 500) {
      # 頁面使用卡片格式（GridView1_lblSchName_N），非傳統 <table>
      # 逐頁抓取（PageControl1$lbNextPage 換頁），上限 200 頁防無窮迴圈
      $currentHtml    = $postHtml
      $currentResp    = $postResp
      $pageNum        = 1
      $maxPages       = 200
      $importedAt     = (Get-Date).ToUniversalTime().ToString("o")

      while ($pageNum -le $maxPages) {
        # 不另存逐頁快照，由 update-data.ps1 統一建檔
        $postSnapPath = $snapFile.Replace($Root, "").TrimStart("\") -replace "\\", "/"

        # 解析卡片格式：GridView1_lblSchName_N / lblCity_N / lblArea_N
        $nameMatches = [regex]::Matches($currentHtml, 'id="GridView1_lblSchName_(\d+)">([^<]+)<')
        $cityMatches = [regex]::Matches($currentHtml, 'id="GridView1_lblCity_(\d+)">([^<]+)<')
        $areaMatches = [regex]::Matches($currentHtml, 'id="GridView1_lblArea_(\d+)">([^<]+)<')
        Write-Host "  第 $pageNum 頁：$($nameMatches.Count) 筆"

        if ($nameMatches.Count -eq 0) { break }

        for ($i = 0; $i -lt $nameMatches.Count; $i++) {
          $instName = [System.Web.HttpUtility]::HtmlDecode($nameMatches[$i].Groups[2].Value.Trim())
          $city     = if ($i -lt $cityMatches.Count) { [System.Web.HttpUtility]::HtmlDecode($cityMatches[$i].Groups[2].Value.Trim()) } else { "" }
          $district = if ($i -lt $areaMatches.Count) { [System.Web.HttpUtility]::HtmlDecode($areaMatches[$i].Groups[2].Value.Trim()) } else { "" }

          if (-not $instName) { continue }

          $dedupKey = ConvertTo-Slug "$instName|moe-penalty"
          if ($seenSet.Contains($dedupKey)) { continue }

          $eventId = "penalty-moe-kg-$(ConvertTo-Slug $instName)"
          # 政府官方公開資料 → 直接 verified（無需人工審核）
          $penaltyEvent = [ordered]@{
            id                 = $eventId
            verificationStatus = "verified"
            autoImported       = $true
            importSource       = "penalty-moe-aspx"
            institution        = [ordered]@{
              name     = $instName
              type     = "幼兒園"
              city     = $city
              district = $district
              address  = ""
              code     = ""
              aliases  = @()
            }
            risk               = "high"
            category           = "penalty"
            title              = "主管機關裁罰：$instName"
            summary            = "此幼兒園列於教育部全國教保資訊網裁罰名單，詳細裁罰事由請查閱官方紀錄。"
            eventDate          = "unknown"
            importedAt         = $importedAt
            tags               = @("政府裁罰", "幼兒園", "已查證")
            evidence           = @(
              [ordered]@{
                title        = "幼兒園裁罰紀錄（全國教保資訊網）"
                publisher    = "教育部"
                url          = $moeUrl
                type         = "government_doc"
                capturedAt   = $snapAt
                snapshotPath = $postSnapPath
                httpStatus   = $currentResp.StatusCode
                status       = "captured"
              }
            )
          }

          [void]$newVerified.Add($penaltyEvent)
          [void]$seenSet.Add($dedupKey)
          Write-Host "  + 幼兒園裁罰（已查證）：$instName（$city $district）"
        }

        # 檢查是否有下一頁：按鈕存在且非 aspNetDisabled
        $hasNextBtn  = [regex]::IsMatch($currentHtml, 'id="PageControl1_lbNextPage"')
        $nextDisabled = [regex]::IsMatch($currentHtml, 'id="PageControl1_lbNextPage"[^>]*class="aspNetDisabled"')
        if (-not $hasNextBtn -or $nextDisabled) {
          Write-Host "  已到最後一頁（共 $pageNum 頁）"
          break
        }

        Start-Sleep -Milliseconds $DelayMs
        $pageNum++

        # 更新 VIEWSTATE 並送出換頁請求
        $pvs  = [regex]::Match($currentHtml, 'name="__VIEWSTATE"\s+id="__VIEWSTATE"\s+value="([^"]*)"').Groups[1].Value
        $pev  = [regex]::Match($currentHtml, 'name="__EVENTVALIDATION"[^>]+value="([^"]*)"').Groups[1].Value
        $nextBody = @{
          "__VIEWSTATE"          = $pvs
          "__VIEWSTATEGENERATOR" = $vsGen
          "__VIEWSTATEENCRYPTED" = ""
          "__EVENTVALIDATION"    = $pev
          "__EVENTTARGET"        = "PageControl1`$lbNextPage"
          "__EVENTARGUMENT"      = ""
          "txtKeyNameS"          = ""
        }
        $currentResp = Invoke-WebRequest -Uri $moeUrl -Method POST -Body $nextBody `
                         -UseBasicParsing -TimeoutSec 60 -WebSession $session `
                         -Headers $postHeaders
        $currentHtml = $currentResp.Content
        Write-Host "  換頁回應：$($currentHtml.Length) 位元組"
      }
    } else {
      Write-Warning "  POST 回應過小（$($postHtml.Length) 位元組），可能遭防火牆封鎖"
    }
  }
} catch {
  Write-Warning "來源 1 抓取失敗：$($_.Exception.Message)"
}

Start-Sleep -Milliseconds $DelayMs

# ---------------------------------------------------------------------------
# 來源 2：教育部政府資料開放平台 — 幼兒園名錄（dataset/6086）
#   用途：提供 JSON 格式裁罰資料（若有）；同時補充機構地址資訊
# ---------------------------------------------------------------------------

$src2Url = "https://data.gov.tw/dataset/6086"
Write-Host "`n[來源 2] 幼兒園名錄 dataset/6086  $src2Url"

try {
  $headers2 = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
  }
  $resp2   = Invoke-WebRequest -Uri $src2Url -UseBasicParsing -TimeoutSec 30 -Headers $headers2
  $html2   = $resp2.Content
  Write-Host "  取得頁面（$($html2.Length) 位元組）"

  $jsonResUrl = Get-LatestJsonResourceUrl $html2
  if ($jsonResUrl) {
    Write-Host "  找到 JSON 資源：$jsonResUrl"
    $resourcePath = Join-Path $datasetDir "moe-kg-dir-$(ConvertTo-Slug $jsonResUrl).json"
    try {
      $client = New-Object System.Net.WebClient
      $bytes  = $client.DownloadData($jsonResUrl)
      [System.IO.File]::WriteAllBytes($resourcePath, $bytes)
      Write-Host "  下載完成，儲存至：$resourcePath"
      # 此為名錄資料，供機構比對使用，不產生裁罰事件
      $dirItems = Read-JsonArrayFile $resourcePath
      Write-Host "  共 $($dirItems.Count) 筆幼兒園名錄記錄（供機構比對用）"
    } catch {
      Write-Warning "  無法下載 JSON 資源：$($_.Exception.Message)"
    }
  } else {
    Write-Host "  頁面中未找到 JSON 資源連結（名錄資料來源僅供參考）"
  }
} catch {
  Write-Warning "來源 2 幼兒園名錄抓取失敗：$($_.Exception.Message)"
}

Start-Sleep -Milliseconds $DelayMs

# ---------------------------------------------------------------------------
# 寫回檔案
# ---------------------------------------------------------------------------

Write-Host "`n=== 結果 ==="

if ($newVerified.Count -gt 0) {
  $mergedEvents = @($existingEvents) + @($newVerified)
  $eventsJson   = $mergedEvents | ConvertTo-Json -Depth 18
  [System.IO.File]::WriteAllText($eventsPath, $eventsJson, [System.Text.Encoding]::UTF8)
  Write-Host "已新增 $($newVerified.Count) 筆已查證裁罰至 $eventsPath"
} else {
  Write-Host "本次無新裁罰記錄（來源 1 可能遭 WAF 封鎖，需人工確認）。"
}

$seenOutput = [ordered]@{
  updatedAt = (Get-Date).ToUniversalTime().ToString("o")
  seen      = @($seenSet)
}
[System.IO.File]::WriteAllText($seenPath, ($seenOutput | ConvertTo-Json -Depth 4), [System.Text.Encoding]::UTF8)
Write-Host "已更新 $seenPath（已知去重鍵：$($seenSet.Count) 筆）"
