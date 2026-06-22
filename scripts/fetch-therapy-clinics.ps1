#Requires -Version 5.1
<#
.SYNOPSIS
  從健保署特約醫事機構開放資料取得提供語言/職能/物理治療服務的機構清單，
  寫入 data/therapy-institutions.json。

.DESCRIPTION
  資料來源：政府資料開放平台 data.gov.tw（轉呼叫健保署 info.nhi.gov.tw API）
    - dataset/39280 健保特約醫事機構-醫學中心
    - dataset/39281 健保特約醫事機構-區域醫院
    - dataset/39282 健保特約醫事機構-地區醫院
    - dataset/39283 健保特約醫事機構-診所

  過濾條件：服務項目包含「復健－語言治療業務」「復健－職能治療業務」「復健－物理治療業務」
  欄位格式：醫事機構代碼,醫事機構名稱,醫事機構種類,電話,地址,分區業務組,
             特約類別,服務項目,診療科別,終止合約或歇業日期,...

.PARAMETER Root
  專案根目錄，預設為本腳本上層目錄。

.PARAMETER DelayMs
  HTTP 請求間隔毫秒。預設 2000。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\fetch-therapy-clinics.ps1
#>
param(
  [string]$Root    = (Split-Path -Parent $PSScriptRoot),
  [int]$DelayMs    = 2000
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.Web.Extensions
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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

# 從 data.gov.tw dataset 頁面取得 contentUrl
function Get-DatasetContentUrl([int]$DatasetId) {
  $url = "https://data.gov.tw/dataset/$DatasetId"
  try {
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent","Mozilla/5.0 (compatible; KidsSafetyWall/1.0)")
    $html = $wc.DownloadString($url)
    $m = [regex]::Match($html, '"contentUrl"\s*:\s*"([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value -replace '\\/','/' }
  } catch {
    Write-Warning "  dataset/$DatasetId 取得失敗: $($_.Exception.Message)"
  }
  return $null
}

# 下載 CSV bytes
function Download-CsvBytes([string]$Url) {
  $wc = New-Object System.Net.WebClient
  $wc.Headers.Add("User-Agent","Mozilla/5.0 (compatible; KidsSafetyWall/1.0)")
  $wc.Headers.Add("Accept","text/csv,application/csv,*/*")
  return $wc.DownloadData($Url)
}

# 解析 CSV（支援引號欄位）→ 回傳 row array（每 row 為 string[]）
function Parse-Csv([string]$Content) {
  $tmp = [System.IO.Path]::GetTempFileName() + ".csv"
  try {
    [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.Encoding]::UTF8)
    return @(Import-Csv -Path $tmp -Encoding UTF8)
  } catch {
    Write-Warning "  CSV 解析失敗: $($_.Exception.Message)"
    return @()
  } finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  }
}

# 從地址解析縣市 / 行政區
function Parse-CityDistrict([string]$Address) {
  $addr = $Address -replace '　',' '  # 全形空格
  $city = ''; $dist = ''
  if ($addr -match '^([^\s縣市]*[縣市])([^\s區鄉鎮市]*[區鄉鎮市])') {
    $city = $Matches[1] -replace '^臺','台'
    $dist = $Matches[2]
  } elseif ($addr -match '^([^\s縣市]*[縣市])') {
    $city = $Matches[1] -replace '^臺','台'
  }
  # 從地址前綴名稱推導縣市（備援）
  if (-not $city) {
    $knownCities = @("台北市","新北市","桃園市","台中市","台南市","高雄市","基隆市","新竹市","嘉義市","新竹縣","苗栗縣","彰化縣","南投縣","雲林縣","嘉義縣","屏東縣","宜蘭縣","花蓮縣","台東縣","澎湖縣","金門縣","連江縣")
    foreach ($c in $knownCities) {
      $tc = $c -replace '^台','臺'
      if ($addr.StartsWith($c) -or $addr.StartsWith($tc)) { $city = $c; break }
    }
  }
  return @{ city = $city; district = $dist }
}

# 從 服務項目 推導 services 陣列
function Parse-Services([string]$ServiceItems) {
  $svcs = [System.Collections.ArrayList]::new()
  if ($ServiceItems -match "語言治療業務") { [void]$svcs.Add("語言治療") }
  if ($ServiceItems -match "職能治療業務") { [void]$svcs.Add("職能治療") }
  if ($ServiceItems -match "物理治療業務") { [void]$svcs.Add("物理治療") }
  return @($svcs)
}

# 從 services 決定 type
function Derive-Type([string[]]$Services) {
  $hasLang = $Services -contains "語言治療"
  $hasOT   = $Services -contains "職能治療"
  $hasPT   = $Services -contains "物理治療"
  $count   = ($hasLang -as [int]) + ($hasOT -as [int]) + ($hasPT -as [int])

  if ($count -ge 2)  { return "復健科診所" }
  if ($hasLang)      { return "語言治療所" }
  if ($hasOT)        { return "職能治療所" }
  if ($hasPT)        { return "物理治療所" }
  return "醫療院所"
}

# ---------------------------------------------------------------------------
# 健保特約醫事機構資料集（NHI API，透過 data.gov.tw contentUrl 取得）
# ---------------------------------------------------------------------------

$nhDatasets = @(
  @{ id = 39280; label = "醫學中心";   fallbackRId = "A21030000I-D21001-003" },
  @{ id = 39281; label = "區域醫院";   fallbackRId = "A21030000I-D21002-005" },
  @{ id = 39282; label = "地區醫院";   fallbackRId = "A21030000I-D21003-003" },
  @{ id = 39283; label = "診所";       fallbackRId = "A21030000I-D21004-009" }
)

# ---------------------------------------------------------------------------
# 主程序
# ---------------------------------------------------------------------------

$dataDir      = Join-Path $Root "data"
$outputPath   = Join-Path $dataDir "therapy-institutions.json"
$snapshotPath = Join-Path $dataDir "nhi-therapy-snapshot.json"

$existing = @(Read-JsonArrayFile $outputPath)
$kept     = @($existing | Where-Object { "$($_["dataSource"])" -ne "nhi-therapy-registry" -and "$($_["dataSource"])" -ne "nhi-therapy-registry-terminated" })
$fresh    = [System.Collections.ArrayList]::new()
$seenKeys = [System.Collections.Generic.HashSet[string]]::new([string[]]@($kept | ForEach-Object { "$($_["key"])" }))

# 載入上次快照（用於偵測消失的機構）
$prevSnapshot   = @(Read-JsonArrayFile $snapshotPath)
$prevByKey      = [System.Collections.Generic.Dictionary[string,object]]::new()
foreach ($s in $prevSnapshot) { $prevByKey["$($s["key"])"] = $s }

Write-Host "=== 兒少防火牆：治療機構清單（健保署特約資料）==="
Write-Host "保留既有非健保系統條目：$($kept.Count) 筆"
Write-Host "上次快照：$($prevSnapshot.Count) 筆"

foreach ($ds in $nhDatasets) {
  Write-Host ""
  Write-Host "--- $($ds.label) (dataset/$($ds.id)) ---"

  # 取 contentUrl
  $contentUrl = Get-DatasetContentUrl $ds.id
  if (-not $contentUrl) {
    $contentUrl = "https://info.nhi.gov.tw/api/iode0000s01/Dataset?rId=$($ds.fallbackRId)"
    Write-Warning "  使用備援 URL"
  }
  Write-Host "  URL: $contentUrl"

  Start-Sleep -Milliseconds $DelayMs

  # 下載 CSV
  $bytes = $null
  try {
    $bytes = Download-CsvBytes $contentUrl
    Write-Host "  下載 $($bytes.Length) bytes"
  } catch {
    Write-Warning "  下載失敗: $($_.Exception.Message)"
    continue
  }

  # 解析 CSV
  $csvText = [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
  # 移除 BOM 後再試
  if ($csvText -match "[\x00-\x08]") {
    $csvText = [System.Text.Encoding]::GetEncoding("big5").GetString($bytes)
  }

  $rows = @(Parse-Csv $csvText)
  Write-Host "  解析 $($rows.Count) 筆"

  $addedCount = 0
  foreach ($row in $rows) {
    $svcItems = "$($row."服務項目")".Trim()
    # 只要有語言/職能/物理治療業務
    if ($svcItems -notmatch "語言治療業務|職能治療業務|物理治療業務") { continue }

    $code          = "$($row."醫事機構代碼")".Trim()
    $name          = "$($row."醫事機構名稱")".Trim()
    $phone         = "$($row."電話")".Trim()
    $address       = "$($row."地址")".Trim() -replace '^臺','台'
    $terminatedRaw = "$($row."終止合約或歇業日期")".Trim()

    if (-not $name) { continue }

    # 判斷健保特約是否已終止（日期為過去日期）
    $isTerminated  = $false
    $terminatedDate = ""
    if ($terminatedRaw -match '^\d{8}$') {
      $terminatedDate = "$($terminatedRaw.Substring(0,4))-$($terminatedRaw.Substring(4,2))-$($terminatedRaw.Substring(6,2))"
      $isTerminated   = ([int]$terminatedRaw) -lt ([int](Get-Date).ToString("yyyyMMdd"))
    }

    $parsed   = Parse-CityDistrict $address
    $city     = $parsed.city
    $dist     = $parsed.district
    $services = @(Parse-Services $svcItems)
    $type     = Derive-Type $services

    $key = if ($code) { "nhi-$code" } else { "therapy-" + (ConvertTo-Slug "$type|$city|$name") }
    if ($seenKeys.Contains($key)) { continue }

    [void]$fresh.Add([ordered]@{
      key              = $key
      name             = $name
      type             = $type
      city             = $city
      district         = $dist
      address          = $address
      phone            = $phone
      services         = $services
      referralRequired = $false
      insurance        = "健保"
      ageMax           = $null
      website          = ""
      penalties        = if ($isTerminated) { 1 } else { 0 }
      news             = 0
      reviews          = 0
      nhiTerminated    = $isTerminated
      nhiTerminatedDate= $terminatedDate
      dataSource       = "nhi-therapy-registry"
      updatedAt        = (Get-Date).ToString("yyyy-MM-dd")
    })
    [void]$seenKeys.Add($key)
    $addedCount++
  }
  Write-Host "  新增治療機構：$addedCount 筆"
  Start-Sleep -Milliseconds $DelayMs
}

$merged = [System.Collections.ArrayList]::new(@(@($kept) + @($fresh)))

# ---------------------------------------------------------------------------
# 歷史比對：與上次快照比較，偵測消失（可能被終止合約）的機構
# ---------------------------------------------------------------------------

$queuePath  = Join-Path $dataDir "review-queue.json"
$eventsPath = Join-Path $dataDir "events.json"

if ($prevSnapshot.Count -gt 0) {
  # 建立本次抓到的 key 集合
  $freshKeySet = [System.Collections.Generic.HashSet[string]]::new()
  foreach ($inst in $fresh) { [void]$freshKeySet.Add("$($inst["key"])") }

  # 載入 review-queue（避免重複建立事件）
  $queue    = [System.Collections.ArrayList]::new(@(Read-JsonArrayFile $queuePath))
  $queueIds = [System.Collections.Generic.HashSet[string]]::new()
  foreach ($q in $queue) { [void]$queueIds.Add("$($q["id"])") }

  $disappearedCount = 0
  foreach ($prev in $prevSnapshot) {
    $prevKey  = "$($prev["key"])"
    $prevName = "$($prev["name"])"
    if ($freshKeySet.Contains($prevKey)) { continue }

    Write-Host "  ⚠ 機構從健保名冊消失：$prevName [$($prev["city"])]（上次合約到期日：$($prev["contractEndDate"])）"

    # 把該機構以「已終止」狀態加回資料（讓使用者能看到警告）
    [void]$merged.Add([ordered]@{
      key               = $prevKey
      name              = $prevName
      type              = "$($prev["type"])"
      city              = "$($prev["city"])"
      district          = "$($prev["district"])"
      address           = "$($prev["address"])"
      phone             = "$($prev["phone"])"
      services          = @($prev["services"] | ForEach-Object { "$_" })
      referralRequired  = $false
      insurance         = "健保"
      ageMax            = $null
      website           = "$($prev["website"])"
      penalties         = 1
      news              = [int]"$($prev["news"])"
      reviews           = 0
      nhiTerminated     = $true
      nhiTerminatedDate = (Get-Date).ToString("yyyy-MM-dd")
      dataSource        = "nhi-therapy-registry-terminated"
      updatedAt         = (Get-Date).ToString("yyyy-MM-dd")
    })

    # 建立 review-queue 事件
    $eventId = "nhi-removed-$prevKey"
    if (-not $queueIds.Contains($eventId)) {
      [void]$queue.Add([ordered]@{
        id          = $eventId
        type        = "nhi-contract-removed"
        title       = "$prevName 已從健保特約名冊移除"
        date        = (Get-Date).ToString("yyyy-MM-dd")
        url         = "https://info.nhi.gov.tw/"
        source      = "健保署特約資料（每日差異比對）"
        institution = [ordered]@{
          key  = $prevKey
          name = $prevName
          type = "$($prev["type"])"
          city = "$($prev["city"])"
        }
        summary     = "此機構（$prevName）出現在上次健保特約名冊（快照日：$($prev["snapshotDate"])），但本次已不在名冊中。可能原因：健保署終止特約、機構自行歇業、或換發醫事機構代碼。請查閱健保署網站確認。"
        status      = "pending"
        createdAt   = (Get-Date).ToString("yyyy-MM-dd")
      })
      [void]$queueIds.Add($eventId)
    }
    $disappearedCount++
  }

  if ($disappearedCount -gt 0) {
    Write-Host "發現 $disappearedCount 筆機構從健保名冊消失，已加入 review-queue 待確認"
    Write-JsonArrayFile $queuePath @($queue)
  } else {
    Write-Host "比對快照：無機構消失（健保名冊穩定）"
  }
}

$allEvents = @()
if (Test-Path -LiteralPath $queuePath)  { $allEvents += @(Read-JsonArrayFile $queuePath) }
if (Test-Path -LiteralPath $eventsPath) { $allEvents += @(Read-JsonArrayFile $eventsPath) }

if ($allEvents.Count -gt 0) {
  $newsCountByName = [System.Collections.Generic.Dictionary[string,int]]::new()
  foreach ($ev in $allEvents) {
    $evInst = $ev["institution"]
    if (-not $evInst) { continue }
    $evName = "$($evInst["name"])".Trim()
    if (-not $evName -or $evName -eq "待人工分類") { continue }
    if ($newsCountByName.ContainsKey($evName)) { $newsCountByName[$evName]++ }
    else { $newsCountByName[$evName] = 1 }
  }

  $updated = 0
  foreach ($inst in $merged) {
    $name = "$($inst["name"])".Trim()
    if ($newsCountByName.ContainsKey($name)) {
      $inst["news"] = $newsCountByName[$name]
      $updated++
    }
  }
  Write-Host "新聞計數回填：$updated 筆機構有相關事件（共掃描 $($allEvents.Count) 則事件）"
}

Write-JsonArrayFile $outputPath @($merged)

# ---------------------------------------------------------------------------
# 儲存本次快照（僅記錄現役健保機構，供下次比對用）
# ---------------------------------------------------------------------------

$snapshot = [System.Collections.ArrayList]::new()
$today    = (Get-Date).ToString("yyyy-MM-dd")
foreach ($inst in $fresh) {
  [void]$snapshot.Add([ordered]@{
    key             = "$($inst["key"])"
    name            = "$($inst["name"])"
    type            = "$($inst["type"])"
    city            = "$($inst["city"])"
    district        = "$($inst["district"])"
    address         = "$($inst["address"])"
    phone           = "$($inst["phone"])"
    services        = @($inst["services"] | ForEach-Object { "$_" })
    website         = "$($inst["website"])"
    news            = [int]"$($inst["news"])"
    contractEndDate = "$($inst["nhiTerminatedDate"])"
    snapshotDate    = $today
  })
}
Write-JsonArrayFile $snapshotPath @($snapshot)
Write-Host "快照更新：$($snapshot.Count) 筆現役機構 → nhi-therapy-snapshot.json"

Write-Host ""
$terminated = @($merged | Where-Object { "$($_["nhiTerminated"])" -eq "True" }).Count
Write-Host "完成：therapy-institutions.json 共 $($merged.Count) 筆（健保資料：$($fresh.Count) 筆，停約：$terminated 筆）"
