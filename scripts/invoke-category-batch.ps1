param(
  [Parameter(Mandatory = $true)]
  [string]$TenantIdOrDomain,

  [Parameter(Mandatory = $true)]
  [string]$AssignmentsCsvPath,

  [switch]$Verify
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $AssignmentsCsvPath)) {
  throw "Assignments CSV not found: $AssignmentsCsvPath"
}

$setCategoryScript = Join-Path $PSScriptRoot 'set-email-category.ps1'
if (-not (Test-Path $setCategoryScript)) {
  throw "Required helper not found: $setCategoryScript"
}

$assignments = Import-Csv -Path $AssignmentsCsvPath
if (-not $assignments -or $assignments.Count -eq 0) {
  throw "Assignments CSV is empty."
}

$missing = $assignments | Where-Object { -not $_.EmailId -or -not $_.Category }
if ($missing) {
  throw "Each CSV row must include EmailId and Category."
}

$results = @()
$groups = $assignments | Group-Object Category
foreach ($group in $groups) {
  $emailIds = @($group.Group | ForEach-Object { $_.EmailId })
  $groupResults = & $setCategoryScript -EmailId $emailIds -Category $group.Name -TenantIdOrDomain $TenantIdOrDomain -Verify:$Verify
  $results += $groupResults
}

$results
