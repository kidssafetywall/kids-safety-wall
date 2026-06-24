#Requires -Version 5.1
param(
    [int]$MaxRequests = 500,
    [int]$DelayMs     = 1300,
    [switch]$Force
)

$ErrorActionPreference = "Continue"
$ScriptDir  = Split-Path $MyInvocation.MyCommand.Path
$DataDir    = Join-Path $ScriptDir "..\data"
$InstPath   = Join-Path $DataDir "institutions.json"
$CachePath  = Join-Path $DataDir "geocache.json"

Write-Host "Loading institutions.json..."
$instJson     = [IO.File]::ReadAllText($InstPath, [Text.Encoding]::UTF8)
$institutions = $instJson | ConvertFrom-Json

# Load or init geocache as hashtable
$cacheDict = [System.Collections.Generic.Dictionary[string,object]]::new()
if (Test-Path $CachePath) {
    $cacheObj = ([IO.File]::ReadAllText($CachePath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
    foreach ($prop in $cacheObj.PSObject.Properties) {
        $cacheDict[$prop.Name] = $prop.Value
    }
}

$total    = $institutions.Count
Write-Host "Institutions : $total"
Write-Host "Cache entries: $($cacheDict.Count)"
Write-Host ""

# Prioritize institutions with events (penalties/news > 0) first
$institutions = @($institutions | Sort-Object {
    $p = if ($_.penalties) { [int]$_.penalties } else { 0 }
    $n = if ($_.news)      { [int]$_.news      } else { 0 }
    $q = if ($_.pending)   { [int]$_.pending   } else { 0 }
    $p + $n + $q
} -Descending)

$queued   = 0
$geocoded = 0
$failed   = 0
$skipped  = 0

foreach ($inst in $institutions) {
    $key = "$($inst.key)"
    if (-not $key) { $skipped++; continue }

    if (-not $Force -and $cacheDict.ContainsKey($key)) {
        $skipped++
        continue
    }

    if ($queued -ge $MaxRequests) { break }

    $city = "$($inst.city)".Replace("臺","台")
    $dist = "$($inst.district)"
    $addr = "$($inst.address)"
    $name = "$($inst.name)"

    if ($addr.Length -gt 4) {
        $query = "$city$addr"
    } elseif ($dist) {
        $query = "$city$dist $name"
    } else {
        $query = "$city $name"
    }

    $queued++

    try {
        $encoded = [Uri]::EscapeDataString($query)
        $url = "https://nominatim.openstreetmap.org/search?q=$encoded&format=json&limit=1&countrycodes=tw&accept-language=zh-TW"

        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers @{
            "User-Agent" = "KidsSafetyWall/1.0 (jbseric66060@gmail.com)"
        } -TimeoutSec 15

        $results = $resp.Content | ConvertFrom-Json

        if ($results -and $results.Count -gt 0) {
            $lat = [double]$results[0].lat
            $lon = [double]$results[0].lon
            if ($lat -gt 21 -and $lat -lt 27 -and $lon -gt 118 -and $lon -lt 123) {
                $cacheDict[$key] = [PSCustomObject]@{ lat = $lat; lng = $lon }
                $geocoded++
                if ($geocoded % 10 -eq 1) {
                    Write-Host "  [$queued/$MaxRequests] $name -> $lat, $lon"
                }
            } else {
                $failed++
            }
        } else {
            $failed++
        }
    } catch {
        $failed++
        Write-Host "  [ERR] $name : $_"
    }

    Start-Sleep -Milliseconds $DelayMs
}

# Save geocache
$saveObj = [PSCustomObject]@{}
foreach ($k in $cacheDict.Keys) {
    $saveObj | Add-Member -NotePropertyName $k -NotePropertyValue $cacheDict[$k] -Force
}
$enc = [System.Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($CachePath, ($saveObj | ConvertTo-Json -Depth 3), $enc)

Write-Host ""
Write-Host "=============================="
Write-Host "  Queried  : $queued"
Write-Host "  Geocoded : $geocoded"
Write-Host "  Failed   : $failed"
Write-Host "  Skipped  : $skipped"
Write-Host "  Cache    : $($cacheDict.Count) total"
Write-Host "=============================="
Write-Host "Run publish-news.bat to apply to site."
