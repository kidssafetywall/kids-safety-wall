param(
  [string]$Root = (Split-Path -Parent $PSScriptRoot),
  [switch]$IncludePending = $false,
  [int]$MaxImportedPerSource = 0
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function ConvertTo-Slug([string]$Text) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 16)
}

function Read-JsonFile([string]$Path, $Fallback) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return $Fallback
  }

  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $Fallback
  }

  return $raw | ConvertFrom-Json
}

function Read-JsonArrayFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return @()
  }

  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $raw = $raw.TrimStart([char]0xFEFF)
  if ($raw.StartsWith("ï»¿")) {
    $raw = $raw.Substring(3)
  }
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return @()
  }

  Add-Type -AssemblyName System.Web.Extensions
  $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  $serializer.MaxJsonLength = 67108864
  try {
    $items = $serializer.DeserializeObject($raw)
  } catch {
    Write-Warning "Read-JsonArrayFile: invalid JSON in '$Path' — $($_.Exception.Message)"
    return @()
  }
  if ($null -eq $items) {
    return @()
  }

  return @($items)
}

function Get-PageSnapshot([string]$Url, [string]$ArchiveDir, [string]$Prefix, [switch]$Force) {
  $id = ConvertTo-Slug $Url
  $file = Join-Path $ArchiveDir "$Prefix-$id.html"
  $capturedAt = (Get-Date).ToUniversalTime().ToString("o")

  if (-not $Force -and (Test-Path -LiteralPath $file)) {
    return @{
      capturedAt    = $capturedAt
      snapshotPath  = ($file.Replace($Root, "").TrimStart("\") -replace "\\", "/")
      httpStatus    = $null
      captureStatus = "cached"
    }
  }

  try {
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30
    $html = @"
<!--
source: $Url
captured_at_utc: $capturedAt
status_code: $($response.StatusCode)
-->
$($response.Content)
"@
    [System.IO.File]::WriteAllText($file, $html, [System.Text.Encoding]::UTF8)
    return @{
      capturedAt = $capturedAt
      snapshotPath = ($file.Replace($Root, "").TrimStart("\") -replace "\\", "/")
      httpStatus = $response.StatusCode
      captureStatus = "captured"
    }
  } catch {
    $msg = $_.Exception.Message
    if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) }
    # 下載失敗時，若舊快照存在則沿用，避免離線時機構清單歸零
    if (Test-Path -LiteralPath $file) {
      Write-Warning "Snapshot download failed, using cached snapshot: $Url"
      return @{
        capturedAt    = $capturedAt
        snapshotPath  = ($file.Replace($Root, "").TrimStart("\") -replace "\\", "/")
        httpStatus    = $null
        captureStatus = "cached: $msg"
      }
    }
    return @{
      capturedAt    = $capturedAt
      snapshotPath  = $null
      httpStatus    = $null
      captureStatus = "capture_failed: $msg"
    }
  }
}

function Get-EventKind($Category) {
  switch ($Category) {
    "news" { "news" }
    "parent_review" { "review" }
    default { "official" }
  }
}

function Get-RiskRank([string]$Risk) {
  switch ($Risk) {
    "high" { 3 }
    "mid" { 2 }
    "low" { 1 }
    default { 2 }
  }
}

function Get-RiskFromRank([int]$Rank) {
  if ($Rank -ge 3) { return "high" }
  if ($Rank -eq 2) { return "mid" }
  return "low"
}

function Get-InstitutionKey($Institution) {
  if ($Institution["code"]) { return [string]$Institution["code"] }
  $city = Format-City $Institution["city"]
  $name = "$($Institution["name"])".Trim()
  return ConvertTo-Slug "$city|$name"
}

function Get-Prop($Item, [string[]]$Names) {
  foreach ($name in $Names) {
    if ($Item.ContainsKey($name) -and $null -ne $Item[$name] -and "$($Item[$name])" -ne "") {
      return "$($Item[$name])"
    }
  }
  return ""
}

function Normalize-ImportedText([string]$Value) {
  if (-not $Value) { return "" }
  return (($Value -replace '^\[[^\]]+\]', '')).Trim()
}

function Format-City([string]$Value) {
  return ("$Value".Replace("臺","台").Replace("　"," ").Trim() -replace '政府$', '')
}

function U([int[]]$Codes) {
  return -join ($Codes | ForEach-Object { [char]$_ })
}

function Get-AllJsonResourceUrls([string]$Html) {
  $m    = [regex]::Matches($Html, '"contentUrl"\s*:\s*"([^"]+)"')
  $urls = [System.Collections.ArrayList]::new()
  foreach ($match in $m) {
    $url = $match.Groups[1].Value.Replace("\/", "/")
    # Accept .json files AND JSP endpoints that serve JSON (e.g. afterschool_json.jsp?city=XX)
    if ($url -match '\.json($|[?#])' -or $url -match 'json\.jsp') {
      [void]$urls.Add($url)
    }
  }
  return @($urls | Select-Object -Unique)
}

function Get-ImportedInstitutions($Source, [string]$DatasetHtml, [string]$DatasetDir, [int]$Limit) {
  $resourceUrls = Get-AllJsonResourceUrls $DatasetHtml
  if ($resourceUrls.Count -eq 0) {
    return @()
  }

  # Download every resource URL and collect items tagged with their source URL
  $taggedItems = [System.Collections.ArrayList]::new()
  foreach ($resourceUrl in $resourceUrls) {
    $resourceId   = ConvertTo-Slug $resourceUrl
    $resourcePath = Join-Path $DatasetDir "$($Source.id)-$resourceId.json"
    if (-not (Test-Path -LiteralPath $resourcePath)) {
      try {
        $resp = Invoke-WebRequest -Uri $resourceUrl -UseBasicParsing -TimeoutSec 20
        [System.IO.File]::WriteAllBytes($resourcePath, $resp.Content)
      } catch {
        Write-Warning "Cannot download resource $resourceUrl for $($Source.id): $($_.Exception.Message)"
        continue
      }
    }
    $fileItems = Read-JsonArrayFile $resourcePath
    Write-Host "  [$($Source.id)] $resourceUrl → $($fileItems.Count) rows"
    foreach ($fi in $fileItems) {
      [void]$taggedItems.Add(@{ item = $fi; url = $resourceUrl })
    }
  }

  # 多學年資料集去重：每個代碼只保留最新學年（幼兒園/國中等資料集有 11 年 × N 所 = 數萬筆）
  $yearField = (U @(0x5b78,0x5e74,0x5ea6))  # 學年度
  $codeField = (U @(0x4ee3,0x78bc))          # 代碼
  $firstItem = if ($taggedItems.Count -gt 0) { $taggedItems[0]["item"] } else { $null }
  if ($firstItem -and $firstItem.ContainsKey($yearField)) {
    $sorted    = @($taggedItems) | Sort-Object { [int]"0$($_['item'][$yearField])" } -Descending
    $seenCodes = [System.Collections.Generic.HashSet[string]]::new()
    $deduped   = [System.Collections.ArrayList]::new()
    foreach ($ti in $sorted) {
      $c = if ($ti["item"].ContainsKey($codeField)) { "$($ti['item'][$codeField])" } else { "" }
      if (-not $c -or $seenCodes.Add($c)) { [void]$deduped.Add($ti) }
    }
    $taggedItems = $deduped
    Write-Host "  [$($Source.id)] 多學年去重後：$($taggedItems.Count) 筆唯一機構"
  }

  $rows = [System.Collections.ArrayList]::new()
  $count = 0
  foreach ($tagged in $taggedItems) {
    $item        = $tagged["item"]
    $resourceUrl = $tagged["url"]
    if ($Limit -gt 0 -and $count -ge $Limit) {
      break
    }

    $nameKeys = @(
      (U @(0x5b78,0x6821,0x540d,0x7a31)),
      (U @(0x77ed,0x671f,0x88dc,0x7fd2,0x73ed,0x540d,0x7a31)),
      (U @(0x6a5f,0x69cb,0x540d,0x7a31)),
      (U @(0x540d,0x7a31)),
      "name"
    )
    $cityKeys = @(
      (U @(0x7e23,0x5e02,0x540d,0x7a31)),
      (U @(0x5730,0x5340,0x7e23,0x5e02)),
      (U @(0x7e23,0x5e02)),
      "CountyName",
      "city"
    )
    $districtKeys = @(
      (U @(0x9109,0x93ae,0x5e02,0x5340,0x540d,0x7a31)),
      (U @(0x884c,0x653f,0x5340)),
      "district"
    )
    $addressKeys = @(
      (U @(0x5730,0x5740)),
      (U @(0x73ed,0x5740)),
      "address"
    )
    $codeKeys = @(
      (U @(0x4ee3,0x78bc)),
      (U @(0x5b78,0x6821,0x4ee3,0x78bc)),
      (U @(0x88dc,0x7fd2,0x73ed,0x4ee3,0x78bc)),
      "code"
    )
    $phoneKeys = @(
      (U @(0x96fb,0x8a71)),
      (U @(0x96fb,0x8a71,0x865f,0x78bc)),
      "phone"
    )
    $websiteKeys = @(
      (U @(0x7db2,0x5740)),
      "website"
    )

    $name = Get-Prop $item $nameKeys
    if (-not $name) {
      continue
    }

    $city = Format-City (Normalize-ImportedText (Get-Prop $item $cityKeys))
    $district = Normalize-ImportedText (Get-Prop $item $districtKeys)
    $address = Normalize-ImportedText (Get-Prop $item $addressKeys)
    $code = Get-Prop $item $codeKeys
    $phone = Get-Prop $item $phoneKeys
    $website = Get-Prop $item $websiteKeys
    $type = if ($Source.entityType) { "$($Source.entityType)" } else { "教育機構" }
    $key = if ($code) { "$($Source.id)-$code" } else { ConvertTo-Slug "$($Source.id)|$city|$name|$address" }

    # Extract 公/私立 category; detect 非營利 from name
    $catRaw = Get-Prop $item @((U @(0x516c, 0x002f, 0x79c1, 0x7acb)))
    $nonProfit = U @(0x975e, 0x71df, 0x5229)
    $instCategory = if ($name -match [regex]::Escape($nonProfit)) { $nonProfit } elseif ($catRaw) { $catRaw } else { "" }

    $count++

    [void]$rows.Add([ordered]@{
      key = $key
      name = $name
      city = $city
      district = $district
      type = $type
      address = $address
      code = $code
      aliases = @()
      instCategory = $instCategory
      risk = "low"
      penalties = 0
      news = 0
      reviews = 0
      pending = 0
      disputed = 0
      updated = (Get-Date).ToString("yyyy-MM-dd")
      tags = @("政府名錄", $type)
      phone = $phone
      website = $website
      dataSourceId = $Source.id
      dataSourceTitle = $Source.title
      dataResourceUrl = $resourceUrl
      xy = @((20 + (Get-Random -Minimum 0 -Maximum 60)), (30 + (Get-Random -Minimum 0 -Maximum 42)))
      events = @()
    })
  }

  return @($rows)
}

$dataDir = Join-Path $Root "data"
$sourceDir = Join-Path $Root "sources"
$archiveDir = Join-Path $Root "archive"
$rawDir = Join-Path $archiveDir "raw"
$datasetDir = Join-Path $archiveDir "datasets"

Ensure-Directory $dataDir
Ensure-Directory $sourceDir
Ensure-Directory $archiveDir
Ensure-Directory $rawDir
Ensure-Directory $datasetDir

$registry = Read-JsonFile (Join-Path $sourceDir "source-registry.json") ([pscustomobject]@{ sources = @() })
$events = Read-JsonArrayFile (Join-Path $dataDir "events.json")
$reviewQueue = Read-JsonArrayFile (Join-Path $dataDir "review-queue.json")
$siteDataPath = Join-Path $dataDir "site-data.js"
$institutionsPath = Join-Path $dataDir "institutions.json"

$sources = @()
$importedInstitutions = @()
foreach ($source in @($registry.sources)) {
  $capture = Get-PageSnapshot -Url $source.datasetUrl -ArchiveDir $rawDir -Prefix $source.id -Force
  $datasetHtml = ""
  if ($capture.snapshotPath) {
    $snapshotFullPath = Join-Path $Root $capture.snapshotPath
    if (Test-Path -LiteralPath $snapshotFullPath) {
      $datasetHtml = Get-Content -LiteralPath $snapshotFullPath -Raw -Encoding UTF8
    }
  }

  $sources += [ordered]@{
    id = $source.id
    title = $source.title
    publisher = $source.publisher
    url = $source.datasetUrl
    updateFrequency = $source.updateFrequency
    capturedAt = $capture.capturedAt
    snapshotPath = $capture.snapshotPath
    status = $capture.captureStatus
  }

  if ($source.type -eq "government_dataset" -and $datasetHtml) {
    $importedInstitutions += Get-ImportedInstitutions -Source $source -DatasetHtml $datasetHtml -DatasetDir $datasetDir -Limit $MaxImportedPerSource
  }
}

$allEvents = @()
$allEvents += $events
if ($IncludePending) {
  $allEvents += $reviewQueue
}

$institutionMap = @{}
foreach ($institution in $importedInstitutions) {
  $institutionMap[$institution.key] = $institution
}

# Build name+city reverse-lookup so events can find existing directory institutions
# (prevents creating duplicate entries when key formats differ)
$nameCityLookup = @{}
foreach ($inst in $institutionMap.Values) {
  $nk = "$(Format-City $inst.city)|$("$($inst.name)".Replace('臺','台').Trim())"
  if (-not $nameCityLookup.ContainsKey($nk)) { $nameCityLookup[$nk] = $inst.key }
}

foreach ($event in $allEvents) {
  if ($event["verificationStatus"] -eq "removed") {
    continue
  }

  $institution = $event["institution"]
  if (-not $institution -or -not $institution["name"]) {
    Write-Warning "Skip event without institution: $($event["id"])"
    continue
  }

  $evidenceList = @($event["evidence"])
  if ($evidenceList.Count -eq 0 -and $event["sourceUrl"]) {
    $evidenceList = @(@{
      title = $event["sourceTitle"]
      publisher = $event["sourcePublisher"]
      url = $event["sourceUrl"]
      type = $event["category"]
    })
  }

  $validEvidence = @($evidenceList | Where-Object { $_["url"] })
  if ($validEvidence.Count -eq 0) {
    Write-Warning "Skip event without evidence URL: $($event["id"])"
    continue
  }

  $capturedEvidence = @()
  foreach ($evidence in $validEvidence) {
    $capture = Get-PageSnapshot -Url $evidence["url"] -ArchiveDir $rawDir -Prefix $event["id"]
    $capturedEvidence += [ordered]@{
      title = $evidence["title"]
      publisher = $evidence["publisher"]
      url = $evidence["url"]
      type = $evidence["type"]
      capturedAt = $capture.capturedAt
      snapshotPath = $capture.snapshotPath
      httpStatus = $capture.httpStatus
      status = $capture.captureStatus
    }
  }

  $key = Get-InstitutionKey $institution
  # Prefer existing directory institution if name+city matches (avoids duplicates)
  $nkCity = Format-City $institution["city"]
  $nkName = "$($institution["name"])".Replace('臺','台').Trim()
  $nk = "$nkCity|$nkName"
  if ($nameCityLookup.ContainsKey($nk)) { $key = $nameCityLookup[$nk] }

  if (-not $institutionMap.ContainsKey($key)) {
    $institutionMap[$key] = [ordered]@{
      key = $key
      name = $institution["name"]
      city = Format-City $institution["city"]
      district = $institution["district"]
      type = $institution["type"]
      address = $institution["address"]
      code = $institution["code"]
      aliases = @($institution["aliases"])
      instCategory = if ($institution["instCategory"]) { "$($institution['instCategory'])" } else { "" }
      risk = "low"
      riskRank = 1
      penalties = 0
      news = 0
      reviews = 0
      pending = 0
      disputed = 0
      updated = (Get-Date).ToString("yyyy-MM-dd")
      tags = @()
      xy = @((20 + (Get-Random -Minimum 0 -Maximum 60)), (30 + (Get-Random -Minimum 0 -Maximum 42)))
      events = @()
    }
  }

  $kind = Get-EventKind $event["category"]
  $eventRisk = if ($event["risk"]) { $event["risk"] } else { "mid" }
  $entry = $institutionMap[$key]
  $entry.riskRank = [Math]::Max($entry.riskRank, (Get-RiskRank $eventRisk))
  $entry.risk = Get-RiskFromRank $entry.riskRank

  if ($kind -eq "official" -and $eventRisk -ne "low") { $entry.penalties++ }
  if ($kind -eq "news") { $entry.news++ }
  if ($kind -eq "review") { $entry.reviews++ }
  if ($event["verificationStatus"] -eq "pending") { $entry.pending++ }
  if ($event["verificationStatus"] -eq "disputed") { $entry.disputed++ }

  foreach ($tag in @($event["tags"])) {
    if ($tag -and -not $entry.tags.Contains($tag)) {
      $entry.tags += $tag
    }
  }

  $entry.events += [ordered]@{
    id = $event["id"]
    kind = $kind
    category = $event["category"]
    verificationStatus = if ($event["verificationStatus"]) { $event["verificationStatus"] } else { "pending" }
    risk = $eventRisk
    title = $event["title"]
    date = $event["eventDate"]
    summary = $event["summary"]
    tags = @($event["tags"])
    evidence = $capturedEvidence
    sourceTitle = $capturedEvidence[0].title
    sourcePublisher = $capturedEvidence[0].publisher
    sourceUrl = $capturedEvidence[0].url
    capturedAt = $capturedEvidence[0].capturedAt
    snapshotPath = $capturedEvidence[0].snapshotPath
    httpStatus = $capturedEvidence[0].httpStatus
    status = $capturedEvidence[0].status
    penaltyDocNumber  = if ($event["penaltyDocNumber"])  { "$($event['penaltyDocNumber'])" }  else { $null }
    penaltyLegalBasis = if ($event["penaltyLegalBasis"]) { "$($event['penaltyLegalBasis'])" } else { $null }
    penaltyViolation  = if ($event["penaltyViolation"])  { "$($event['penaltyViolation'])" }  else { $null }
    penaltyContent    = if ($event["penaltyContent"])    { "$($event['penaltyContent'])" }    else { $null }
    penaltyRespondent = if ($event["penaltyRespondent"]) { "$($event['penaltyRespondent'])" } else { $null }
  }
}

$institutions = @($institutionMap.Values | ForEach-Object {
  $_.Remove("riskRank")
  $_
} | Sort-Object name)

# Apply quasi-public.json — tag matching 私立 institutions as 準公共
$quasiPath = Join-Path $dataDir "quasi-public.json"
if (Test-Path $quasiPath) {
  $quasiArr = ([IO.File]::ReadAllText($quasiPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  # Build lookup by normalized name
  $quasiNames = @{}
  foreach ($q in $quasiArr) {
    $n = "$($q.name)".Replace("臺","台").Trim()
    $quasiNames[$n] = $true
  }
  $quasiTagged = 0
  foreach ($inst in $institutions) {
    if ($inst["instCategory"] -eq "私立") {
      $n = "$($inst.name)".Replace("臺","台").Trim()
      if ($quasiNames.ContainsKey($n)) {
        $inst["instCategory"] = "準公共"
        $quasiTagged++
      }
    }
  }
  if ($quasiTagged -gt 0) { Write-Host "  Tagged $quasiTagged institutions as 準公共" }
}

# Apply institution-overrides.json (manual closed/歇業 flags)
$overridesPath = Join-Path $dataDir "institution-overrides.json"
if (Test-Path $overridesPath) {
  $overridesArr = ([IO.File]::ReadAllText($overridesPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  $overrideDict = @{}
  foreach ($o in $overridesArr) { $overrideDict["$($o.key)"] = $o }
  $overrideApplied = 0
  foreach ($inst in $institutions) {
    $k = "$($inst.key)"
    if ($overrideDict.ContainsKey($k)) {
      $ov = $overrideDict[$k]
      $inst["closed"] = if ($ov.closed) { $true } else { $false }
      if ($ov.closedNote) { $inst["closedNote"] = "$($ov.closedNote)" }
      $overrideApplied++
    }
  }
  if ($overrideApplied -gt 0) { Write-Host "  Applied $overrideApplied institution overrides (closed flags)" }
}

# Merge geocache coordinates
$geocachePath = Join-Path $dataDir "geocache.json"
if (Test-Path $geocachePath) {
  $geoObj = ([IO.File]::ReadAllText($geocachePath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  $geoMerged = 0
  foreach ($inst in $institutions) {
    $k = "$($inst.key)"
    $entry = $geoObj.PSObject.Properties[$k]
    if ($entry -and $entry.Value -and $entry.Value.lat) {
      $inst["lat"] = [double]$entry.Value.lat
      $inst["lng"] = [double]$entry.Value.lng
      $geoMerged++
    }
  }
  if ($geoMerged -gt 0) { Write-Host "  Merged $geoMerged geocache coordinates" }
}

$payload = [ordered]@{
  generatedAt = (Get-Date).ToString("o")
  captureNote = "Every event must include at least one evidence URL. Evidence pages are saved under archive/raw and exposed as original links plus local snapshots."
  sources = $sources
  institutions = $institutions
}

Add-Type -AssemblyName System.Web.Extensions
$jss = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$jss.MaxJsonLength = [int]::MaxValue
$json = $jss.Serialize($payload)
$js = "window.SAFETY_WALL_DATA = $json;"
[System.IO.File]::WriteAllText($siteDataPath, $js, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($institutionsPath, $jss.Serialize($institutions), [System.Text.Encoding]::UTF8)

Write-Host "Updated $siteDataPath"
Write-Host "Updated $institutionsPath"
Write-Host "Captured $($sources.Count) registered sources and built $($institutions.Count) institutions from $($allEvents.Count) events."
