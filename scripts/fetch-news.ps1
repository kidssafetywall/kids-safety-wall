#Requires -Version 5.1
<#
.SYNOPSIS
  從 Google News RSS 抓取教育機構相關負面新聞，寫入 data/review-queue.json 待人工審核。

.PARAMETER Root
  專案根目錄，預設為本腳本上層目錄。

.PARAMETER MaxNewPerRun
  單次執行最多新增幾筆事件，避免一次塞入過多待審項目。預設 50。

.PARAMETER DelayMs
  每次 RSS 查詢之間的等待毫秒數，避免被封鎖。預設 2000。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\fetch-news.ps1
  powershell -ExecutionPolicy Bypass -File .\scripts\fetch-news.ps1 -MaxNewPerRun 20
#>
param(
  [string]$Root             = (Split-Path -Parent $PSScriptRoot),
  [int]$MaxNewPerRun        = 50,
  [int]$DelayMs             = 2000,
  [int]$MaxSpecificQueries  = 100
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.Web.Extensions

# ---------------------------------------------------------------------------
# 共用工具函式（與 update-data.ps1 相同模式，各腳本獨立避免 dot-source 相依）
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

function Get-PageSnapshot([string]$Url, [string]$ArchiveDir, [string]$Prefix, [switch]$Force) {
  $id          = ConvertTo-Slug $Url
  $file        = Join-Path $ArchiveDir "$Prefix-$id.html"
  $capturedAt  = (Get-Date).ToUniversalTime().ToString("o")

  if (-not $Force -and (Test-Path -LiteralPath $file)) {
    return @{
      capturedAt    = $capturedAt
      snapshotPath  = ($file.Replace($Root, "").TrimStart("\") -replace "\\", "/")
      httpStatus    = $null
      captureStatus = "cached"
    }
  }

  try {
    $headers  = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36" }
    $resp     = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -Headers $headers
    $content  = $resp.Content

    # Skip Google News relay pages — they contain a JS redirect, not the article
    if ($content -match '<base\s+href="https://news\.google\.com/' -or
        $content -match 'window\.location\.replace\(' -and $Url -match 'news\.google\.com') {
      return @{
        capturedAt    = $capturedAt
        snapshotPath  = $null
        httpStatus    = $resp.StatusCode
        captureStatus = "skipped_relay_page"
      }
    }

    $comment  = "<!--`nsource: $Url`ncaptured_at_utc: $capturedAt`nstatus_code: $($resp.StatusCode)`n-->`n"
    [System.IO.File]::WriteAllText($file, $comment + $content, [System.Text.Encoding]::UTF8)
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
# 路徑設定
# ---------------------------------------------------------------------------

$dataDir    = Join-Path $Root "data"
$archiveDir = Join-Path $Root "archive"
$rawDir     = Join-Path $archiveDir "raw"

Ensure-Directory $rawDir

$seenPath   = Join-Path $dataDir "news-seen.json"
$queuePath  = Join-Path $dataDir "review-queue.json"
$eventsPath = Join-Path $dataDir "events.json"

# ---------------------------------------------------------------------------
# 載入已知資料
# ---------------------------------------------------------------------------

# 已抓取的 RSS guid 與文章 URL（去重用）
# 同時追蹤 URL 是因為 Google News 對同一篇文章可能在不同查詢時給出不同的 guid，
# 但原始文章 URL 較穩定，能防止同一篇文章被重複送審。
$seenRaw = if (Test-Path -LiteralPath $seenPath) {
  Get-Content -LiteralPath $seenPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
  [pscustomobject]@{ updatedAt = ""; seen = @(); seenUrls = @() }
}
$seenSet    = [System.Collections.Generic.HashSet[string]]::new([string[]]@($seenRaw.seen))
$seenUrls   = [System.Collections.Generic.HashSet[string]]::new([string[]]@($seenRaw.seenUrls))

# 現有待審佇列（用於最後合併）
$existingQueue  = Read-JsonArrayFile $queuePath
# 已知事件（用於取得已追蹤機構名稱）
$existingEvents = Read-JsonArrayFile $eventsPath

# 已在佇列/事件中的機構（避免針對「待分類」或「資料源」的假條目建立查詢）
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

# ---------------------------------------------------------------------------
# 組建查詢清單
# ---------------------------------------------------------------------------

# 確認性行動關鍵字（政府/法院處分、人事懲處、性平事件、不當管教、監察院糾正）
$neg = "裁罰 OR 停辦 OR 撤銷立案 OR 廢止立案 OR 勒令停辦 OR 廢園 OR 判決確定 OR 判刑 OR 罰款 OR 行政處分 OR 坦承 OR 認罪 OR 自首 OR 監視器畫面 OR 監視器錄影 OR 性平 OR 性騷擾 OR 性侵害 OR 性霸凌 OR 霸凌 OR 不當管教 OR 體罰 OR 辱罵 OR 解聘 OR 停聘 OR 不續聘 OR 不適任 OR 記過 OR 申誡 OR 監察院糾正"

# 通用查詢：按機構類型抓最新相關新聞
$queries = [System.Collections.ArrayList]::new()
@(
  # 各機構類型 + 廣泛負面事件詞
  @{ q = "幼兒園 ($neg)";                       type = "幼兒園";       name = "待人工分類" },
  @{ q = "國小 OR 國民小學 ($neg)";              type = "國小";         name = "待人工分類" },
  @{ q = "國中 OR 國民中學 ($neg)";              type = "國中";         name = "待人工分類" },
  @{ q = "高中 OR 高職 OR 高中職 ($neg)";        type = "高中職";       name = "待人工分類" },
  @{ q = "補習班 ($neg)";                        type = "補習班";       name = "待人工分類" },
  @{ q = "課後照顧中心 ($neg)";                  type = "課後照顧中心"; name = "待人工分類" },

  # 不適任教師（跨學校類型，精準度高）
  @{ q = "不適任教師 (解聘 OR 停聘 OR 性騷擾 OR 性侵害 OR 霸凌 OR 體罰)"; type = "學校"; name = "待人工分類" },
  @{ q = "教師 (解聘 OR 停聘 OR 不續聘) (性騷擾 OR 性侵害 OR 性霸凌 OR 不當管教 OR 霸凌)"; type = "學校"; name = "待人工分類" },

  # 校園性別事件（性平會調查、性平委員）
  @{ q = "校園性別事件 (調查報告 OR 性平會 OR 解聘 OR 停聘 OR 申訴)";  type = "學校"; name = "待人工分類" },
  @{ q = "性別平等教育法 (違反 OR 調查 OR 教育局 OR 學校)";            type = "學校"; name = "待人工分類" },

  # 監察院糾正（地方教育局失職、程序瑕疵）
  @{ q = "監察院 糾正 (學校 OR 教育局 OR 幼兒園 OR 校園)";             type = "學校"; name = "待人工分類" },

  # 人本教育基金會（體罰熱線蒐集源）
  @{ q = "人本教育基金會 (體罰 OR 霸凌 OR 不當管教 OR 解聘 OR 學校)";  type = "學校"; name = "待人工分類" },

  # 教育局行政處分學校
  @{ q = "教育局 (限期改善 OR 要求修正 OR 減招 OR 停辦 OR 行政處分) (學校 OR 幼兒園 OR 補習班)"; type = "學校"; name = "待人工分類" },

  # 校安通報、個資外洩
  @{ q = "校園安全通報 OR 個資外洩 (學校 OR 教師 OR 教育局)";          type = "學校"; name = "待人工分類" },

  # 早療 / 治療機構負面事件（裁罰、不當行為）
  @{ q = "語言治療所 OR 職能治療所 OR 物理治療所 ($neg)";                       type = "治療機構"; name = "待人工分類" },
  @{ q = "早療機構 OR 早期療育機構 OR 聯合評估中心 ($neg)";                      type = "早療機構"; name = "待人工分類" },

  # 治療師性侵/性騷擾（精準度高，確認性詞彙）
  @{ q = "治療師 (性侵 OR 猥褻 OR 性騷擾) (兒童 OR 孩子 OR 學生 OR 判決 OR 起訴 OR 認罪)"; type = "治療機構"; name = "待人工分類" },
  @{ q = "語言治療師 OR 職能治療師 OR 物理治療師 (性侵 OR 性騷擾 OR 不當對待 OR 解聘 OR 判決)"; type = "治療機構"; name = "待人工分類" },

  # 兒童福利機構（涵蓋社福型早療機構、課後托育）
  @{ q = "兒童福利機構 OR 身心障礙福利機構 ($neg)";                              type = "兒童福利機構"; name = "待人工分類" }
) | ForEach-Object { [void]$queries.Add($_) }

# 專項查詢：已追蹤機構（持續監控已知問題機構，每次上限 $MaxSpecificQueries 筆）
$specificAdded = 0
foreach ($inst in $knownInstitutions.Values) {
  if ($specificAdded -ge $MaxSpecificQueries) { break }
  [void]$queries.Add([ordered]@{
    q        = "`"$($inst.name)`""
    type     = $inst.type
    name     = $inst.name
    city     = $inst.city
    specific = $true
  })
  $specificAdded++
}

# 機構名稱快查表（用於從新聞標題自動辨識機構，減少「待人工分類」數量）
$institutionsPath = Join-Path $dataDir "institutions.json"
$allInstitutions  = Read-JsonArrayFile $institutionsPath
$instNameLookup   = [ordered]@{}
foreach ($inst in $allInstitutions) {
  $n = "$($inst["name"])"
  if ($n.Length -ge 4 -and -not $instNameLookup.Contains($n)) {
    $instNameLookup[$n] = $inst
  }
}

# 早療機構也納入快查表
$therapyPath = Join-Path $dataDir "therapy-institutions.json"
if (Test-Path -LiteralPath $therapyPath) {
  $therapyInsts = Read-JsonArrayFile $therapyPath
  $therapyAdded = 0
  foreach ($inst in $therapyInsts) {
    $n = "$($inst["name"])"
    if ($n.Length -ge 4 -and -not $instNameLookup.Contains($n)) {
      $instNameLookup[$n] = $inst
      $therapyAdded++
    }
  }
  Write-Host "早療機構加入快查表：$therapyAdded 筆"
}

Write-Host "機構名稱快查表：$($instNameLookup.Count) 筆（含早療機構）"

Write-Host "=== 兒少防火牆：新聞抓取 ==="
Write-Host "通用查詢：$($queries.Count - $specificAdded) 筆  專項查詢：$specificAdded/$($knownInstitutions.Count) 筆  上限：$MaxNewPerRun 筆新事件"

# ---------------------------------------------------------------------------
# 逐一查詢 Google News RSS
# ---------------------------------------------------------------------------

$newEvents = [System.Collections.ArrayList]::new()
$totalNew  = 0

foreach ($entry in $queries) {
  if ($totalNew -ge $MaxNewPerRun) {
    Write-Host "已達本次上限 ($MaxNewPerRun)，停止查詢。"
    break
  }

  $encoded = [System.Uri]::EscapeDataString($entry.q)
  $rssUrl  = "https://news.google.com/rss/search?q=$encoded&hl=zh-TW&gl=TW&ceid=TW:zh-Hant"

  Write-Host "`n[查詢] $($entry.q)"

  try {
    $rssResp = Invoke-WebRequest -Uri $rssUrl -UseBasicParsing -TimeoutSec 30 -Headers @{
      "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
      "Accept"     = "application/rss+xml, application/xml, text/xml, */*"
    }
    [xml]$rss = $rssResp.Content
  } catch {
    Write-Warning "RSS 查詢失敗：$($_.Exception.Message)"
    Start-Sleep -Milliseconds $DelayMs
    continue
  }

  $items = @($rss.rss.channel.item)
  Write-Host "  取得 $($items.Count) 則"

  foreach ($item in $items) {
    if ($totalNew -ge $MaxNewPerRun) { break }

    # 取得 guid 作為去重鍵，同時取得原始文章 URL 作為輔助去重鍵
    $guid = if ($item.guid -is [System.Xml.XmlElement]) { $item.guid.InnerText } else { "$($item.guid)" }
    if (-not $guid) { $guid = "$($item.link)" }
    $articleUrlRaw = "$($item.link)"
    if ($seenSet.Contains($guid)) { continue }
    if ($articleUrlRaw -and $seenUrls.Contains($articleUrlRaw)) { continue }

    # 解析日期
    $eventDate = "unknown"
    try {
      $dt        = [datetime]::Parse("$($item.pubDate)", [Globalization.CultureInfo]::InvariantCulture)
      $eventDate = $dt.ToString("yyyy-MM-dd")
    } catch {}

    # 解析標題與媒體名稱（Google News 格式：「標題 - 媒體名」）
    $rawTitle  = Strip-Html "$($item.title)"
    $publisher = ""
    $title     = $rawTitle
    if ($rawTitle -match '^(.+?)\s+-\s+([^-]+)$') {
      $title     = $Matches[1].Trim()
      $publisher = $Matches[2].Trim()
    }
    if (-not $publisher -and $item.source) {
      $srcText   = if ($item.source -is [System.Xml.XmlElement]) { $item.source.InnerText } else { "$($item.source)" }
      $publisher = Strip-Html $srcText
    }

    # 摘要（剝離 HTML，截至 200 字）
    $summary = Strip-Html "$($item.description)"
    if ($summary.Length -gt 200) { $summary = $summary.Substring(0, 200) + "…" }

    # 文章 URL
    $articleUrl = "$($item.link)"

    # 對文章執行快照封存
    Write-Host "  + 封存：$title"
    $capture = Get-PageSnapshot -Url $articleUrl -ArchiveDir $rawDir -Prefix "news"

    # 建立事件物件
    $eventId    = "news-$(ConvertTo-Slug $guid)"
    $importedAt = (Get-Date).ToUniversalTime().ToString("o")

    $instCity = if ($entry.ContainsKey("city") -and $entry.city) { $entry.city } else { "" }

    # 嘗試從標題自動辨識機構（僅對通用查詢「待人工分類」有效）
    $autoInst = $null
    if ($entry.name -eq "待人工分類" -and $instNameLookup.Count -gt 0) {
      foreach ($iName in $instNameLookup.Keys) {
        if ($title.Contains($iName)) {
          $autoInst = $instNameLookup[$iName]
          break
        }
      }
    }

    $resolvedName = if ($autoInst) { "$($autoInst["name"])" } else { $entry.name }
    $resolvedType = if ($autoInst) { "$($autoInst["type"])" } else { $entry.type }
    $resolvedCity = if ($autoInst) { "$($autoInst["city"])" } else { $instCity }
    $resolvedDist = if ($autoInst) { "$($autoInst["district"])" } else { "" }
    $autoTag      = if ($autoInst) { Write-Host "  → 自動辨識：$resolvedName（$resolvedCity）"; "自動辨識" } else { $null }

    $newEvent = [ordered]@{
      id                 = $eventId
      verificationStatus = "pending"
      autoImported       = $true
      importSource       = "google-news-rss"
      searchQuery        = $entry.q
      institution        = [ordered]@{
        name     = $resolvedName
        type     = $resolvedType
        city     = $resolvedCity
        district = $resolvedDist
        address  = ""
        code     = ""
        aliases  = @()
      }
      risk               = "mid"
      category           = "news"
      title              = $title
      summary            = $summary
      eventDate          = $eventDate
      importedAt         = $importedAt
      tags               = @("自動匯入", "新聞", $resolvedType) + @(if ($autoTag) { $autoTag } else { @() })
      evidence           = @(
        [ordered]@{
          title        = $title
          publisher    = $publisher
          url          = $articleUrl
          type         = "news"
          capturedAt   = $capture.capturedAt
          snapshotPath = $capture.snapshotPath
          httpStatus   = $capture.httpStatus
          status       = $capture.captureStatus
        }
      )
    }

    [void]$newEvents.Add($newEvent)
    [void]$seenSet.Add($guid)
    if ($articleUrlRaw) { [void]$seenUrls.Add($articleUrlRaw) }
    $totalNew++
  }

  Start-Sleep -Milliseconds $DelayMs
}

# ---------------------------------------------------------------------------
# 寫回檔案
# ---------------------------------------------------------------------------

if ($newEvents.Count -gt 0) {
  # 合併舊佇列與新事件，序列化後寫回
  $merged      = @($existingQueue) + @($newEvents)
  $prettyJson  = $merged | ConvertTo-Json -Depth 18
  [System.IO.File]::WriteAllText($queuePath, $prettyJson, [System.Text.Encoding]::UTF8)
  Write-Host "`n已新增 $($newEvents.Count) 筆事件至 $queuePath"
} else {
  Write-Host "`n沒有新事件。"
}

# 更新 news-seen.json
$seenOutput = [ordered]@{
  updatedAt = (Get-Date).ToUniversalTime().ToString("o")
  seen      = @($seenSet)
  seenUrls  = @($seenUrls)
}
[System.IO.File]::WriteAllText($seenPath, ($seenOutput | ConvertTo-Json -Depth 4), [System.Text.Encoding]::UTF8)
Write-Host "已更新 $seenPath（已知 guid：$($seenSet.Count) 筆，URL：$($seenUrls.Count) 筆）"
