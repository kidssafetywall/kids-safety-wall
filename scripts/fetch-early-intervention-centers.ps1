#Requires -Version 5.1
<#
.SYNOPSIS
  從衛福部社家署及政府資料開放平台抓取聯合評估中心、早期療育機構清單，
  附加寫入 data/therapy-institutions.json。

.DESCRIPTION
  資料來源：
    1. 政府資料開放平台 (data.gov.tw) — 衛生福利部社家署早期療育相關資料集
    2. 衛福部社家署官網解析（作為備援）

  機構類型：聯合評估中心、早期療育機構（社福型）

.PARAMETER Root
  專案根目錄，預設為本腳本上層目錄。

.PARAMETER DelayMs
  每次 HTTP 請求之間的等待毫秒。預設 1500。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\fetch-early-intervention-centers.ps1
#>
param(
  [string]$Root    = (Split-Path -Parent $PSScriptRoot),
  [int]$DelayMs    = 1500
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.Web.Extensions
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# 共用工具函式
# ---------------------------------------------------------------------------

function ConvertTo-Slug([string]$Text) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $sha   = [System.Security.Cryptography.SHA256]::Create()
  (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 16)
}

# 深度轉換 JavaScriptSerializer 反序列化結果為純 hashtable（避免 PSParameterizedProperty 循環參考）
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
  # ConvertTo-Json 支援 OrderedDictionary，JavaScriptSerializer 不支援
  $json = $Array | ConvertTo-Json -Depth 6 -Compress
  if ($null -eq $json) { $json = "[]" }
  # 確保輸出為 JSON array
  if ($json -notmatch '^\[') { $json = "[$json]" }
  [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
}

function Strip-Html([string]$Html) {
  if (-not $Html) { return "" }
  $t = $Html -replace '<[^>]+>', ' '
  $t = [System.Web.HttpUtility]::HtmlDecode($t)
  return ($t -replace '\s+', ' ').Trim()
}

function Get-Prop($Row, [string[]]$Keys) {
  foreach ($k in $Keys) {
    $v = $null
    try { $v = $Row[$k] } catch {}
    if ($null -ne $v -and "$v".Trim() -ne "") { return "$v".Trim() }
  }
  return ""
}

function Import-CsvBytes([byte[]]$Bytes) {
  $content = $null
  try   { $content = [System.Text.Encoding]::UTF8.GetString($Bytes).TrimStart([char]0xFEFF) } catch {}
  if (-not $content -or $content -match "[\x00-\x08\x0E-\x1F]") {
    try { $content = [System.Text.Encoding]::GetEncoding("big5").GetString($Bytes) } catch {}
  }
  if (-not $content) { return @() }
  $tmp = [System.IO.Path]::GetTempFileName() + ".csv"
  try {
    [System.IO.File]::WriteAllText($tmp, $content, [System.Text.Encoding]::UTF8)
    return @(Import-Csv -Path $tmp -Encoding UTF8)
  } catch {
    Write-Warning "CSV 解析失敗: $($_.Exception.Message)"
    return @()
  } finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  }
}

# ---------------------------------------------------------------------------
# data.gov.tw API 搜尋
# ---------------------------------------------------------------------------

function Find-DatasetDownloadUrl([string]$Query) {
  $encoded   = [System.Uri]::EscapeDataString($Query)
  $searchUrl = "https://data.gov.tw/api/v2/rest/dataset?q=$encoded&size=10&page=1"
  try {
    $resp    = Invoke-WebRequest -Uri $searchUrl -UseBasicParsing -TimeoutSec 30 -Headers @{
      "User-Agent" = "Mozilla/5.0 (compatible; KidsSafetyWall/1.0)"
      "Accept"     = "application/json"
    }
    $data    = $resp.Content | ConvertFrom-Json
    $results = @()
    if ($data.result -and $data.result.results) { $results = @($data.result.results) }
    elseif ($data.results) { $results = @($data.results) }

    foreach ($r in $results) {
      $dists = @()
      if ($r.distribution) { $dists = @($r.distribution) }
      elseif ($r.resources) { $dists = @($r.resources)   }
      foreach ($d in $dists) {
        $url = if ($d.downloadURL) { $d.downloadURL } elseif ($d.url) { $d.url } else { "" }
        $fmt = if ($d.format)      { $d.format      } elseif ($d.mediaType) { $d.mediaType } else { "" }
        if ($url -and ($fmt -match "csv|json|CSV|JSON" -or $url -match "\.(csv|json)(\?|$)")) {
          return $url
        }
      }
    }
  } catch {
    Write-Warning "data.gov.tw 搜尋失敗 ($Query): $($_.Exception.Message)"
  }
  return $null
}

# ---------------------------------------------------------------------------
# 備援：解析衛福部社家署早療資源頁面（HTML table）
# ---------------------------------------------------------------------------

function Get-SfaaEarlyInterventionCenters {
  # 衛福部社家署「發展遲緩兒童早期療育服務資源」
  $url = "https://www.sfaa.gov.tw/SFAA/Pages/Detail.aspx?nodeid=269&pid=316"
  Write-Host "  備援：解析社家署早療資源頁面..."
  try {
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -Headers @{
      "User-Agent" = "Mozilla/5.0"
      "Accept"     = "text/html"
    }
    $html = $resp.Content
    $centers = [System.Collections.ArrayList]::new()

    # 解析 <table> 中的機構資料（每列含縣市、機構名稱、電話、地址）
    $tablePattern = '(?is)<tr[^>]*>(.*?)</tr>'
    $tdPattern    = '(?is)<td[^>]*>(.*?)</td>'
    $rows = [regex]::Matches($html, $tablePattern)

    foreach ($row in $rows) {
      $cells = @([regex]::Matches($row.Groups[1].Value, $tdPattern) | ForEach-Object { Strip-Html $_.Groups[1].Value })
      if ($cells.Count -lt 3) { continue }

      # 常見格式：縣市 | 機構名稱 | 電話 | 地址
      $name = ""
      $city = ""
      $tel  = ""
      $addr = ""

      if ($cells.Count -ge 4) {
        $city = ($cells[0] -replace "臺", "台").Trim()
        $name = $cells[1].Trim()
        $tel  = $cells[2].Trim()
        $addr = $cells[3].Trim()
      } elseif ($cells.Count -eq 3) {
        $name = $cells[0].Trim()
        $tel  = $cells[1].Trim()
        $addr = $cells[2].Trim()
      }

      if (-not $name -or $name -match "^(機構名稱|單位名稱|名稱)$") { continue }
      if (-not $city -and $addr -match "^(台北市|新北市|桃園市|台中市|台南市|高雄市|基隆市|新竹市|嘉義市|新竹縣|苗栗縣|彰化縣|南投縣|雲林縣|嘉義縣|屏東縣|宜蘭縣|花蓮縣|台東縣|澎湖縣|金門縣|連江縣)") {
        $city = $Matches[1]
      }

      [void]$centers.Add([ordered]@{
        name = $name; city = $city; phone = $tel; address = $addr
      })
    }
    Write-Host "  社家署頁面解析：$($centers.Count) 筆"
    return @($centers)
  } catch {
    Write-Warning "  社家署頁面解析失敗: $($_.Exception.Message)"
    return @()
  }
}

# ---------------------------------------------------------------------------
# 早療資料集定義
# ---------------------------------------------------------------------------

$earlyIntDefs = @(
  @{
    query    = "早期療育機構基本資料"
    type     = "早療機構"
    services = @("語言治療", "職能治療", "早療課程")
  },
  @{
    query    = "兒童發展聯合評估中心"
    type     = "聯合評估中心"
    services = @("聯合評估", "語言治療", "職能治療", "物理治療", "心理評估")
  }
)

$nameKeys  = @("機構名稱", "單位名稱", "醫事機構名稱", "名稱")
$cityKeys  = @("縣市別", "縣市名稱", "縣市")
$distKeys  = @("鄉鎮市區別", "鄉鎮市區", "行政區")
$addrKeys  = @("地址", "機構地址")
$phoneKeys = @("電話", "聯絡電話", "電話號碼")

# ---------------------------------------------------------------------------
# 主程序
# ---------------------------------------------------------------------------

$dataDir    = Join-Path $Root "data"
$outputPath = Join-Path $dataDir "therapy-institutions.json"

$existing = @(Read-JsonArrayFile $outputPath)
$kept     = @($existing | Where-Object { "$($_["dataSource"])" -ne "sfaa-early-intervention" })
$fresh    = [System.Collections.ArrayList]::new()
$existingKeys = [System.Collections.Generic.HashSet[string]]::new(
  [string[]]@($kept | ForEach-Object { "$($_["key"])" })
)

Write-Host "=== 兒少防火牆：聯合評估中心 / 早療機構抓取 ==="
Write-Host "既有條目保留：$($kept.Count) 筆"

# --- 嘗試從 data.gov.tw 抓取 ---
foreach ($def in $earlyIntDefs) {
  Write-Host ""
  Write-Host "--- $($def.type) ($($def.query)) ---"

  $downloadUrl = Find-DatasetDownloadUrl $def.query
  if (-not $downloadUrl) {
    Write-Host "  data.gov.tw 查無資料集，略過（將由備援方式補充）"
    continue
  }
  Write-Host "  下載: $downloadUrl"
  Start-Sleep -Milliseconds $DelayMs

  $bytes = $null
  try {
    $client = New-Object System.Net.WebClient
    $bytes  = $client.DownloadData($downloadUrl)
  } catch {
    Write-Warning "  下載失敗: $($_.Exception.Message)"
    continue
  }

  $rows = @()
  if ($downloadUrl -match "\.json(\?|$)") {
    $content = [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = 67108864
    $parsed = $ser.DeserializeObject($content)
    if ($parsed -is [System.Collections.ArrayList]) { $rows = @($parsed) }
    elseif ($parsed -is [System.Collections.IDictionary] -and $parsed["data"]) { $rows = @($parsed["data"]) }
  } else {
    $rows = @(Import-CsvBytes $bytes)
  }
  Write-Host "  解析 $($rows.Count) 筆"

  $added = 0
  foreach ($row in $rows) {
    $name = Get-Prop $row $nameKeys
    if (-not $name) { continue }
    $city = (Get-Prop $row $cityKeys) -replace "臺", "台"
    $dist = Get-Prop $row $distKeys
    $addr = Get-Prop $row $addrKeys
    $tel  = Get-Prop $row $phoneKeys

    if (-not $city -and $addr -match "^(台北市|新北市|桃園市|台中市|台南市|高雄市|基隆市|新竹市|嘉義市|新竹縣|苗栗縣|彰化縣|南投縣|雲林縣|嘉義縣|屏東縣|宜蘭縣|花蓮縣|台東縣|澎湖縣|金門縣|連江縣)") {
      $city = $Matches[1]
    }

    $key = "early-" + (ConvertTo-Slug "$($def.type)|$city|$name")
    if ($existingKeys.Contains($key)) { continue }

    [void]$fresh.Add([ordered]@{
      key              = $key
      name             = $name
      type             = $def.type
      city             = $city
      district         = $dist
      address          = $addr
      phone            = $tel
      services         = $def.services
      referralRequired = ($def.type -eq "聯合評估中心")
      insurance        = "健保"
      ageMax           = 6
      website          = ""
      penalties        = 0
      news             = 0
      dataSource       = "sfaa-early-intervention"
      updatedAt        = (Get-Date).ToString("yyyy-MM-dd")
    })
    [void]$existingKeys.Add($key)
    $added++
  }
  Write-Host "  新增 $added 筆"
  Start-Sleep -Milliseconds $DelayMs
}

# --- 備援：解析社家署網頁（聯合評估中心）---
if (($fresh | Where-Object { "$($_["type"])" -eq "聯合評估中心" }).Count -eq 0) {
  Write-Host ""
  Write-Host "--- 備援：社家署網頁解析（聯合評估中心）---"
  Start-Sleep -Milliseconds $DelayMs
  $fallbackCenters = @(Get-SfaaEarlyInterventionCenters)
  $added = 0
  foreach ($c in $fallbackCenters) {
    $name = "$($c["name"])".Trim()
    $city = "$($c["city"])".Trim()
    if (-not $name) { continue }

    $key = "early-" + (ConvertTo-Slug "聯合評估中心|$city|$name")
    if ($existingKeys.Contains($key)) { continue }

    [void]$fresh.Add([ordered]@{
      key              = $key
      name             = $name
      type             = "聯合評估中心"
      city             = $city
      district         = ""
      address          = "$($c["address"])".Trim()
      phone            = "$($c["phone"])".Trim()
      services         = @("聯合評估", "語言治療", "職能治療", "物理治療", "心理評估")
      referralRequired = $true
      insurance        = "健保"
      ageMax           = 6
      website          = ""
      penalties        = 0
      news             = 0
      dataSource       = "sfaa-early-intervention"
      updatedAt        = (Get-Date).ToString("yyyy-MM-dd")
    })
    [void]$existingKeys.Add($key)
    $added++
  }
  Write-Host "  備援新增 $added 筆"
}

$merged = @($kept) + @($fresh)
Write-JsonArrayFile $outputPath $merged
Write-Host ""
Write-Host "完成：therapy-institutions.json 共 $($merged.Count) 筆（本次新增：$($fresh.Count) 筆）"
