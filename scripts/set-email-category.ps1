param(
  [Parameter(Mandatory = $true)]
  [string[]]$EmailId,

  [Parameter(Mandatory = $true)]
  [string]$Category,

  [Parameter(Mandatory = $true)]
  [string]$TenantIdOrDomain,

  [switch]$Verify
)

$ErrorActionPreference = 'Stop'

$clientId = 'bedcc45e-f222-4bf5-ab17-f1357216a522'
$tenantId = $TenantIdOrDomain.Trim()
$scopes = @('Mail.ReadWrite', 'offline_access')
$scopeString = ($scopes -join ' ')
$tokenEndpoint = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
$tokenCachePath = Join-Path $PSScriptRoot 'graph-token-cache.json'

if ($tenantId -in @('common', 'organizations', 'consumers')) {
  throw "TenantIdOrDomain must be a tenant-specific value (GUID or verified domain), not '$tenantId'."
}

function ConvertTo-Base64Url {
  param([byte[]]$Bytes)

  [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-QueryValue {
  param(
    [string]$QueryString,
    [string]$Name
  )

  foreach ($pair in $QueryString.TrimStart('?').Split('&')) {
    if (-not $pair) { continue }
    $parts = $pair.Split('=', 2)
    $key = [System.Uri]::UnescapeDataString($parts[0])
    if ($key -eq $Name) {
      if ($parts.Count -gt 1) {
        return [System.Uri]::UnescapeDataString($parts[1].Replace('+', ' '))
      }
      return ''
    }
  }
  return $null
}

function Get-TokenCache {
  if (-not (Test-Path $tokenCachePath)) {
    return $null
  }
  try {
    Get-Content -Path $tokenCachePath -Raw | ConvertFrom-Json
  }
  catch {
    return $null
  }
}

function Save-TokenCache {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$TokenResponse,
    [string]$FallbackRefreshToken
  )

  $refreshTokenToStore = $TokenResponse.refresh_token
  if (-not $refreshTokenToStore) {
    $refreshTokenToStore = $FallbackRefreshToken
  }

  $expiresIn = [int]$TokenResponse.expires_in
  $expiresAt = (Get-Date).ToUniversalTime().AddSeconds($expiresIn - 120)
  $cache = [pscustomobject]@{
    tenant_id     = $tenantId
    client_id     = $clientId
    access_token  = $TokenResponse.access_token
    refresh_token = $refreshTokenToStore
    expires_at    = $expiresAt.ToString('o')
    scope         = $TokenResponse.scope
  }
  $cache | ConvertTo-Json -Depth 5 | Set-Content -Path $tokenCachePath -Encoding UTF8
}

function Request-TokenInteractive {
  $redirectUri = 'http://localhost'
  $port = 80
  $verifierBytes = New-Object byte[] 32
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($verifierBytes)
  $codeVerifier = ConvertTo-Base64Url $verifierBytes
  $challengeBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::ASCII.GetBytes($codeVerifier))
  $codeChallenge = ConvertTo-Base64Url $challengeBytes
  $stateBytes = New-Object byte[] 16
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($stateBytes)
  $state = ConvertTo-Base64Url $stateBytes

  $authorizeUri = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/authorize?client_id=$clientId&response_type=code&redirect_uri=$([System.Uri]::EscapeDataString($redirectUri))&response_mode=query&scope=$([System.Uri]::EscapeDataString($scopeString))&code_challenge=$codeChallenge&code_challenge_method=S256&state=$state&prompt=select_account"

  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
  try {
    $listener.Start()
  }
  catch {
    throw "Failed to start local redirect listener on ${redirectUri}: $($_.Exception.Message)"
  }

  Write-Host "Open the following sign-in URL if the browser does not appear automatically:"
  Write-Host $authorizeUri
  Start-Process $authorizeUri | Out-Null

  $client = $listener.AcceptTcpClient()
  try {
    $stream = $client.GetStream()
    $buffer = New-Object byte[] 8192
    $count = $stream.Read($buffer, 0, $buffer.Length)
    $requestText = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $count)
    $requestLine = ($requestText -split "`r`n")[0]
    if ($requestLine -notmatch 'GET\s+(\S+)\s+HTTP/1\.[01]') {
      throw "Unexpected redirect request."
    }

    $path = $Matches[1]
    $code = Get-QueryValue -QueryString ([System.Uri]::new("http://localhost$path").Query) -Name 'code'
    $returnedState = Get-QueryValue -QueryString ([System.Uri]::new("http://localhost$path").Query) -Name 'state'
    $authError = Get-QueryValue -QueryString ([System.Uri]::new("http://localhost$path").Query) -Name 'error'
    $authErrorDescription = Get-QueryValue -QueryString ([System.Uri]::new("http://localhost$path").Query) -Name 'error_description'

    $responseBody = if ($authError) {
      "<html><body>Sign-in failed: $authError. You can close this tab.</body></html>"
    }
    else {
      "<html><body>Sign-in received. You can close this tab.</body></html>"
    }
    $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($responseBody)
    $header = "HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($responseBytes.Length)`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    $stream.Write($responseBytes, 0, $responseBytes.Length)
    $stream.Flush()

    if ($authError) {
      if ($authErrorDescription) {
        throw "Authorization failed in browser: $authError - $authErrorDescription"
      }
      throw "Authorization failed in browser: $authError"
    }
    if (-not $code) {
      throw "Authorization code not found in redirect."
    }
    if ($returnedState -ne $state) {
      throw "Authorization state mismatch."
    }

    Invoke-RestMethod -Method Post -Uri $tokenEndpoint -ContentType 'application/x-www-form-urlencoded' -Body @{
      client_id     = $clientId
      grant_type    = 'authorization_code'
      code          = $code
      redirect_uri  = $redirectUri
      code_verifier = $codeVerifier
      scope         = $scopeString
    }
  }
  finally {
    $client.Close()
    $listener.Stop()
  }
}

$tokenResponse = $null
$cache = Get-TokenCache
if ($cache -and $cache.tenant_id -eq $tenantId -and $cache.client_id -eq $clientId) {
  $cacheExpiry = $null
  if ($cache.expires_at) {
    try { $cacheExpiry = [datetime]::Parse($cache.expires_at).ToUniversalTime() } catch {}
  }
  if ($cache.access_token -and $cacheExpiry -and $cacheExpiry -gt (Get-Date).ToUniversalTime()) {
    $tokenResponse = [pscustomobject]@{
      access_token  = $cache.access_token
      refresh_token = $cache.refresh_token
      expires_in    = 3600
      scope         = $cache.scope
    }
  }
  elseif ($cache.refresh_token) {
    try {
      $tokenResponse = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -ContentType 'application/x-www-form-urlencoded' -Body @{
        client_id     = $clientId
        grant_type    = 'refresh_token'
        refresh_token = $cache.refresh_token
        scope         = $scopeString
      }
      Save-TokenCache -TokenResponse $tokenResponse -FallbackRefreshToken $cache.refresh_token
    }
    catch {
      $tokenResponse = $null
    }
  }
}

if (-not $tokenResponse) {
  $tokenResponse = Request-TokenInteractive
  Save-TokenCache -TokenResponse $tokenResponse -FallbackRefreshToken $null
}

$token = $tokenResponse.access_token
$headers = @{
  Authorization = "Bearer $token"
  'Content-Type' = 'application/json'
}

$results = @()
foreach ($singleEmailId in $EmailId) {
  $escapedId = [System.Uri]::EscapeDataString($singleEmailId)
  $patchUri = "https://graph.microsoft.com/v1.0/me/messages/$escapedId"
  $currentUriBuilder = [System.UriBuilder]::new($patchUri)
  $currentUriBuilder.Query = '$select=id,subject,categories,isRead'
  $current = Invoke-RestMethod -Method Get -Uri $currentUriBuilder.Uri.AbsoluteUri -Headers $headers
  $currentCategories = @()
  if ($current.categories) {
    $currentCategories = @($current.categories)
  }
  $normalizedTarget = $Category.Trim().ToLowerInvariant()
  $hasCategory = $false
  foreach ($existingCategory in $currentCategories) {
    if ($existingCategory -and $existingCategory.ToString().Trim().ToLowerInvariant() -eq $normalizedTarget) {
      $hasCategory = $true
      break
    }
  }
  if ($hasCategory) {
    $results += [pscustomobject]@{
      success    = $true
      emailId    = $singleEmailId
      category   = $Category
      action     = 'skipped'
      categories = $currentCategories
    }
    continue
  }

  $newCategories = @($currentCategories)
  $newCategories += $Category
  $body = @{ categories = $newCategories } | ConvertTo-Json -Depth 5

  try {
    Invoke-RestMethod -Method Patch -Uri $patchUri -Headers $headers -Body $body | Out-Null
  }
  catch {
    $details = $null
    if ($_.Exception.Response -and $_.Exception.Response.GetResponseStream()) {
      $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
      $details = $reader.ReadToEnd()
      $reader.Dispose()
    }
    if ($details) {
      throw "PATCH failed for message '$singleEmailId': $details"
    }
    throw "PATCH failed for message '$singleEmailId': $($_.Exception.Message)"
  }

  if ($Verify) {
    $verifyUriBuilder = [System.UriBuilder]::new($patchUri)
    $verifyUriBuilder.Query = '$select=id,subject,categories,isRead'
    $results += Invoke-RestMethod -Method Get -Uri $verifyUriBuilder.Uri.AbsoluteUri -Headers $headers
  }
  else {
    $results += [pscustomobject]@{
      success    = $true
      emailId    = $singleEmailId
      category   = $Category
      action     = 'updated'
      categories = $newCategories
    }
  }
}

$results
