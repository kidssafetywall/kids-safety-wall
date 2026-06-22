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

       每筆機構進一步抓取 punish_view.aspx?sch=... 以取得：
         處分日期、裁處文號、處分依據、違反規定、負責人/行為人、處分內容

    2. 教育部幼兒園名錄（政府資料開放平台 dataset/6086）
       用於比對機構名稱，補充地址等資訊

  所有來自政府官方網站的裁罰紀錄 → events.json（verified，無需人工審核）

.PARAMETER Root
  專案根目錄，預設為本腳本上層目錄。

.PARAMETER DelayMs
  每次搜尋頁 HTTP 請求之間的等待毫秒。預設 2000。
  詳情頁使用 DelayMs 的一半（最少 500ms）。

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
  try {
    $items = $serializer.DeserializeObject($raw)
  } catch {
    Write-Warning "Read-JsonArrayFile: invalid JSON in '$Path' — $($_.Exception.Message)"
    return @()
  }
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
  # Western date with slashes e.g. 2025/07/02
  if ($Value -match '^(\d{4})/(\d{1,2})/(\d{1,2})$') {
    return "$($Matches[1])-$($Matches[2].PadLeft(2,'0'))-$($Matches[3].PadLeft(2,'0'))"
  }
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
$detailDelayMs = [Math]::Max(500, [int]($DelayMs / 2))

# ---------------------------------------------------------------------------
# 載入已知資料
# ---------------------------------------------------------------------------

$seenRaw = if (Test-Path -LiteralPath $seenPath) {
  $raw = Get-Content -LiteralPath $seenPath -Raw -Encoding UTF8
  $raw | ConvertFrom-Json
} else {
  [pscustomobject]@{ version = 2; updatedAt = ""; docs = @(); instSeen = @() }
}

# 格式升級：v1（只有 seen 陣列）→ v2（docs + instSeen）
# 清除舊記錄，重新抓取完整裁罰詳情
if ($null -eq $seenRaw.version -or $seenRaw.version -lt 2) {
  Write-Host "penalty-seen.json 格式升級（v1→v2）：重新抓取完整裁罰詳情..."
  $seenRaw = [pscustomobject]@{ version = 2; updatedAt = ""; docs = @(); instSeen = @() }
}

$seenDocSet  = [System.Collections.Generic.HashSet[string]]::new([string[]]@($seenRaw.docs))
$seenInstSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($seenRaw.instSeen))

$existingEvents = Read-JsonArrayFile $eventsPath
$newVerified    = [System.Collections.ArrayList]::new()

# ---------------------------------------------------------------------------
# 來源 1：教育部全國教保資訊網 — 裁罰紀錄查詢
#   URL: https://ap.ece.moe.edu.tw/webecems/punishSearch.aspx
#   須兩步驟：GET 取得 VIEWSTATE → POST 送出搜尋
#   所有記錄均為政府公開資料 → verified（無需人工審核）
# ---------------------------------------------------------------------------

$moeUrl    = "https://ap.ece.moe.edu.tw/webecems/punishSearch.aspx"
$detailBase = "https://ap.ece.moe.edu.tw/webecems/dtl/punish_view.aspx"
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

  # 儲存搜尋表單快照（作為佐證 URL 基準）
  $snapId   = ConvertTo-Slug $moeUrl
  $snapFile = Join-Path $rawDir "penalty-moe-kg-$snapId.html"
  $snapAt   = (Get-Date).ToUniversalTime().ToString("o")
  [System.IO.File]::WriteAllText($snapFile, "<!--`nsource: $moeUrl`ncaptured_at_utc: $snapAt`n-->`n" + $getHtml, [System.Text.Encoding]::UTF8)
  $postSnapPath = $snapFile.Replace($Root, "").TrimStart("\") -replace "\\", "/"

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
      # 逐頁收集機構列表，再批次抓取裁罰詳情
      $currentHtml    = $postHtml
      $currentResp    = $postResp
      $pageNum        = 1
      $maxPages       = 200
      $importedAt     = (Get-Date).ToUniversalTime().ToString("o")

      # 蒐集所有機構（分頁結束後再抓詳情）
      $allInstitutions = [System.Collections.ArrayList]::new()

      while ($pageNum -le $maxPages) {
        # 解析卡片格式
        $nameMatches = [regex]::Matches($currentHtml, 'id="GridView1_lblSchName_(\d+)">([^<]+)<')
        $cityMatches = [regex]::Matches($currentHtml, 'id="GridView1_lblCity_(\d+)">([^<]+)<')
        $areaMatches = [regex]::Matches($currentHtml, 'id="GridView1_lblArea_(\d+)">([^<]+)<')
        # sch 參數：punish_view.aspx?sch=VALUE&#39;
        $schMatches  = [regex]::Matches($currentHtml, 'punish_view\.aspx\?sch=([A-Za-z0-9+/=]+)&#39;')
        Write-Host "  第 $pageNum 頁：$($nameMatches.Count) 筆"

        if ($nameMatches.Count -eq 0) { break }

        for ($i = 0; $i -lt $nameMatches.Count; $i++) {
          $instName = [System.Web.HttpUtility]::HtmlDecode($nameMatches[$i].Groups[2].Value.Trim())
          $city     = if ($i -lt $cityMatches.Count) { [System.Web.HttpUtility]::HtmlDecode($cityMatches[$i].Groups[2].Value.Trim()) } else { "" }
          $district = if ($i -lt $areaMatches.Count) { [System.Web.HttpUtility]::HtmlDecode($areaMatches[$i].Groups[2].Value.Trim()) } else { "" }
          $schParam = if ($i -lt $schMatches.Count) { $schMatches[$i].Groups[1].Value } else { "" }

          if (-not $instName) { continue }

          [void]$allInstitutions.Add([ordered]@{
            name     = $instName
            city     = $city
            district = $district
            sch      = $schParam
          })
        }

        # 檢查是否有下一頁
        $hasNextBtn   = [regex]::IsMatch($currentHtml, 'id="PageControl1_lbNextPage"')
        $nextDisabled = [regex]::IsMatch($currentHtml, 'id="PageControl1_lbNextPage"[^>]*class="aspNetDisabled"')
        if (-not $hasNextBtn -or $nextDisabled) {
          Write-Host "  已到最後一頁（共 $pageNum 頁）"
          break
        }

        Start-Sleep -Milliseconds $DelayMs
        $pageNum++

        # 更新 VIEWSTATE 並送出換頁請求（捕捉網路錯誤，保留已蒐集資料）
        try {
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
        } catch {
          Write-Warning "  第 $pageNum 頁換頁失敗，保留已蒐集 $($allInstitutions.Count) 筆機構繼續處理：$($_.Exception.Message)"
          break
        }
      }

      Write-Host "`n  共蒐集 $($allInstitutions.Count) 筆機構，開始抓取裁罰詳情..."

      # 逐機構抓取 punish_view.aspx 詳情頁
      $detailCount    = 0
      $skipCount      = 0
      $fallbackCount  = 0

      foreach ($inst in $allInstitutions) {
        $instName = $inst.name
        $city     = $inst.city
        $district = $inst.district
        $schParam = $inst.sch

        # 若此機構已有詳細紀錄（instSeen 已記錄），跳過重複抓取
        $instKey = ConvertTo-Slug "$instName|moe-inst"
        if ($seenInstSet.Contains($instKey)) {
          $skipCount++
          continue
        }

        $penaltyRows = [System.Collections.ArrayList]::new()

        if ($schParam) {
          try {
            Start-Sleep -Milliseconds $detailDelayMs

            $viewUrl   = "${detailBase}?sch=${schParam}"
            $detailHeaders = $postHeaders.Clone()
            $detailHeaders["Referer"] = $moeUrl
            $detailResp  = Invoke-WebRequest -Uri $viewUrl -UseBasicParsing -TimeoutSec 30 `
                             -WebSession $session -Headers $detailHeaders
            $detailHtml  = $detailResp.Content

            # 儲存詳情快照（以機構名稱 hash 命名）
            $detailSnapId   = ConvertTo-Slug $instName
            $detailSnapFile = Join-Path $rawDir "penalty-moe-detail-$detailSnapId.html"
            $detailSnapAt   = (Get-Date).ToUniversalTime().ToString("o")
            [System.IO.File]::WriteAllText($detailSnapFile,
              "<!--`nsource: $viewUrl`ncaptured_at_utc: $detailSnapAt`n-->`n" + $detailHtml,
              [System.Text.Encoding]::UTF8)
            $detailSnapPath = $detailSnapFile.Replace($Root, "").TrimStart("\") -replace "\\", "/"

            # 解析裁罰表格：PDate / PGNum / PName / PDetail / PObject / PContent
            $pDateMs  = [regex]::Matches($detailHtml, 'id="GridView1_lblPDate_(\d+)">([^<]+)<')
            $pGNumMs  = [regex]::Matches($detailHtml, 'id="GridView1_lblPGNum_(\d+)">([^<]+)<')
            $pNameMs  = [regex]::Matches($detailHtml, '(?is)id="GridView1_lblPName_(\d+)">(.+?)</span>')
            $pDetlMs  = [regex]::Matches($detailHtml, '(?is)id="GridView1_lblPDetail_(\d+)">(.+?)</span>')
            $pObjMs   = [regex]::Matches($detailHtml, '(?is)id="GridView1_lblPObject_(\d+)">(.+?)</span>')
            $pCntMs   = [regex]::Matches($detailHtml, '(?is)id="GridView1_lblPContent_(\d+)">(.+?)</span>')

            for ($j = 0; $j -lt $pGNumMs.Count; $j++) {
              $pGNum = [System.Web.HttpUtility]::HtmlDecode($pGNumMs[$j].Groups[2].Value.Trim())
              if (-not $pGNum) { continue }

              $pDate  = if ($j -lt $pDateMs.Count) { $pDateMs[$j].Groups[2].Value.Trim()    } else { "" }
              $pLaw   = if ($j -lt $pNameMs.Count) { Strip-Html $pNameMs[$j].Groups[2].Value } else { "" }
              $pVio   = if ($j -lt $pDetlMs.Count) { Strip-Html $pDetlMs[$j].Groups[2].Value } else { "" }
              $pWho   = if ($j -lt $pObjMs.Count)  { Strip-Html $pObjMs[$j].Groups[2].Value  } else { "" }
              $pFine  = if ($j -lt $pCntMs.Count)  { Strip-Html $pCntMs[$j].Groups[2].Value  } else { "" }

              [void]$penaltyRows.Add([ordered]@{
                GNum      = $pGNum
                Date      = $pDate
                Law       = $pLaw
                Violation = $pVio
                Who       = $pWho
                Fine      = $pFine
                SnapPath  = $detailSnapPath
                SnapAt    = $detailSnapAt
                ViewUrl   = $viewUrl
              })
            }
            Write-Host "  + 詳情：$instName（$($penaltyRows.Count) 筆裁罰紀錄）"
          } catch {
            Write-Warning "  無法抓取 $instName 詳情：$($_.Exception.Message)"
          }
        }

        if ($penaltyRows.Count -gt 0) {
          # 逐筆裁罰文號建立獨立事件
          foreach ($row in $penaltyRows) {
            $docKey = "doc:$($row.GNum)"
            if ($seenDocSet.Contains($docKey)) { continue }

            $penaltyDate = Normalize-RocDate $row.Date

            # 摘要：整合所有關鍵欄位
            $summaryParts = [System.Collections.ArrayList]::new()
            if ($row.Date)      { [void]$summaryParts.Add("處分日期：$($row.Date)") }
            if ($row.GNum)      { [void]$summaryParts.Add("裁處文號：$($row.GNum)") }
            if ($row.Violation) { [void]$summaryParts.Add("違反規定：$($row.Violation)") }
            if ($row.Fine)      { [void]$summaryParts.Add("處分內容：$($row.Fine)") }
            $summary = $summaryParts -join "｜"

            # 標題：取違反規定前 30 字
            $titleVio = $row.Violation
            if ($titleVio -and $titleVio.Length -gt 30) { $titleVio = $titleVio.Substring(0, 30) + "…" }
            $eventTitle = if ($titleVio) { "主管機關裁罰：$titleVio" } else { "主管機關裁罰：$instName" }

            $eventId = "penalty-moe-doc-$(ConvertTo-Slug $row.GNum)"

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
              title              = $eventTitle
              summary            = $summary
              eventDate          = $penaltyDate
              penaltyDocNumber   = $row.GNum
              penaltyLegalBasis  = $row.Law
              penaltyViolation   = $row.Violation
              penaltyContent     = $row.Fine
              penaltyRespondent  = $row.Who
              importedAt         = $importedAt
              tags               = @("政府裁罰", "幼兒園", "已查證")
              evidence           = @(
                [ordered]@{
                  title        = "幼兒園裁罰詳情（全國教保資訊網）"
                  publisher    = "教育部"
                  url          = $moeUrl
                  type         = "government_doc"
                  capturedAt   = $row.SnapAt
                  snapshotPath = $row.SnapPath
                  httpStatus   = 200
                  status       = "captured"
                }
              )
            }

            [void]$newVerified.Add($penaltyEvent)
            [void]$seenDocSet.Add($docKey)
            $detailCount++
            Write-Host "    ✓ $($row.Date) $($row.GNum)（$($row.Fine)）"
          }

          # 標記此機構已完整擷取詳情（下次跳過）
          [void]$seenInstSet.Add($instKey)
        } else {
          # 詳情抓取失敗，回退為基本事件
          $fallbackKey = ConvertTo-Slug "$instName|moe-penalty"
          if (-not $seenDocSet.Contains($fallbackKey)) {
            $eventId = "penalty-moe-kg-$(ConvertTo-Slug $instName)"
            $penaltyEvent = [ordered]@{
              id                 = $eventId
              verificationStatus = "verified"
              autoImported       = $true
              importSource       = "penalty-moe-aspx"
              institution        = [ordered]@{
                name = $instName; type = "幼兒園"; city = $city; district = $district
                address = ""; code = ""; aliases = @()
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
                  httpStatus   = 200
                  status       = "captured"
                }
              )
            }
            [void]$newVerified.Add($penaltyEvent)
            [void]$seenDocSet.Add($fallbackKey)
            $fallbackCount++
          }
        }
      }

      Write-Host "`n  詳情抓取完成：新增 $detailCount 筆、略過（已有）$skipCount 筆、回退 $fallbackCount 筆"
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
#   用途：補充機構地址資訊，不產生裁罰事件
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
      $dirItems = Read-JsonArrayFile $resourcePath
      Write-Host "  共 $($dirItems.Count) 筆幼兒園名錄記錄（供機構比對用）"
    } catch {
      Write-Warning "  無法下載 JSON 資源：$($_.Exception.Message)"
    }
  } else {
    Write-Host "  頁面中未找到 JSON 資源連結"
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
  # 取代所有舊的 penalty-moe-aspx 事件（確保詳情升級）
  $otherEvents  = @($existingEvents | Where-Object { $_["importSource"] -ne "penalty-moe-aspx" })
  $mergedEvents = @($otherEvents) + @($newVerified)
  $eventsJson   = $mergedEvents | ConvertTo-Json -Depth 18
  [System.IO.File]::WriteAllText($eventsPath, $eventsJson, [System.Text.Encoding]::UTF8)
  Write-Host "已寫入 $($newVerified.Count) 筆裁罰事件（含 $detailCount 筆有詳細原因）至 $eventsPath"
} else {
  Write-Host "本次無新裁罰記錄（來源 1 可能遭 WAF 封鎖，需人工確認）。"
}

$seenOutput = [ordered]@{
  version   = 2
  updatedAt = (Get-Date).ToUniversalTime().ToString("o")
  docs      = @($seenDocSet)
  instSeen  = @($seenInstSet)
}
[System.IO.File]::WriteAllText($seenPath, ($seenOutput | ConvertTo-Json -Depth 4), [System.Text.Encoding]::UTF8)
Write-Host "已更新 $seenPath（已知裁罰文號：$($seenDocSet.Count) 筆，已擷取詳情機構：$($seenInstSet.Count) 筆）"
