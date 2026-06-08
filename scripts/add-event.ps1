param(
  [Parameter(Mandatory=$true)][string]$Id,
  [Parameter(Mandatory=$true)][string]$InstitutionName,
  [Parameter(Mandatory=$true)][string]$InstitutionType,
  [Parameter(Mandatory=$true)][string]$City,
  [string]$District = "",
  [string]$Address = "",
  [ValidateSet("low","mid","high")][string]$Risk = "mid",
  [ValidateSet("government_penalty","news","court","parent_review","government_dataset")][string]$Category = "news",
  [ValidateSet("pending","verified","disputed")][string]$VerificationStatus = "pending",
  [Parameter(Mandatory=$true)][string]$Title,
  [Parameter(Mandatory=$true)][string]$Summary,
  [Parameter(Mandatory=$true)][string]$EventDate,
  [Parameter(Mandatory=$true)][string]$EvidenceTitle,
  [Parameter(Mandatory=$true)][string]$EvidencePublisher,
  [Parameter(Mandatory=$true)][string]$EvidenceUrl,
  [string[]]$Tags = @()
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$queuePath = Join-Path $root "data\review-queue.json"

if (Test-Path -LiteralPath $queuePath) {
  $queue = @(Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json)
} else {
  $queue = @()
}

$item = [ordered]@{
  id = $Id
  verificationStatus = $VerificationStatus
  institution = [ordered]@{
    name = $InstitutionName
    type = $InstitutionType
    city = $City
    district = $District
    address = $Address
    code = ""
    aliases = @()
  }
  risk = $Risk
  category = $Category
  title = $Title
  summary = $Summary
  eventDate = $EventDate
  tags = @($Tags)
  evidence = @([ordered]@{
    title = $EvidenceTitle
    publisher = $EvidencePublisher
    url = $EvidenceUrl
    type = $Category
  })
}

$queue = @($queue | Where-Object { $_.id -ne $Id })
$queue += $item
[System.IO.File]::WriteAllText($queuePath, ($queue | ConvertTo-Json -Depth 12), [System.Text.Encoding]::UTF8)
Write-Host "Added event '$Id' to $queuePath"
