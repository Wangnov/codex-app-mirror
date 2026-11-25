param(
  [string] $OutDir = "dist",
  [string] $ManifestPath = "",
  [string] $ProductId = "9PLM9XGG6VKS",
  [string] $PackageIdentity = "OpenAI.Codex",
  [switch] $RequireArm64,
  [int] $StoreLinkMaxAttempts = 12,
  [int] $StoreLinkRetryDelaySeconds = 30,
  [int] $DownloadMaxAttempts = 4,
  [int] $DownloadRetryDelaySeconds = 10
)

$ErrorActionPreference = "Stop"

if ($StoreLinkMaxAttempts -lt 1) {
  throw "StoreLinkMaxAttempts must be at least 1."
}

if ($StoreLinkRetryDelaySeconds -lt 0) {
  throw "StoreLinkRetryDelaySeconds must be non-negative."
}

if ($DownloadMaxAttempts -lt 1) {
  throw "DownloadMaxAttempts must be at least 1."
}

if ($DownloadRetryDelaySeconds -lt 0) {
  throw "DownloadRetryDelaySeconds must be non-negative."
}

function Resolve-ExpectedCatalogSha256 {
  param(
    [object] $Catalog,
    [string] $ExpectedPackageMoniker
  )

  if ($null -eq $Catalog -or -not $ExpectedPackageMoniker) {
    return ""
  }

  $catalogPackage = [string] ($Catalog.packageFullName ?? "")
  if (-not $catalogPackage -or -not $catalogPackage.Equals($ExpectedPackageMoniker, [StringComparison]::OrdinalIgnoreCase)) {
    return ""
  }

  $algorithm = ([string] ($Catalog.hashAlgorithm ?? "")).Trim()
  $rawHash = ([string] ($Catalog.hash ?? "")).Trim()
  if (-not $algorithm) {
    if ($rawHash) {
      throw "Catalog hash provided without hashAlgorithm for $ExpectedPackageMoniker."
    }
    return ""
  }
  if (-not $algorithm.Equals("SHA256", [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsupported catalog hashAlgorithm '$algorithm' for $ExpectedPackageMoniker."
  }
  if (-not $rawHash) {
    throw "Empty or whitespace catalog SHA-256 hash for $ExpectedPackageMoniker."
  }

  if ($rawHash -match '^[0-9a-fA-F]{64}$') {
    return $rawHash.ToLowerInvariant()
  }

  try {
    $bytes = [Convert]::FromBase64String($rawHash)
  } catch {
    throw "Invalid Base64 catalog SHA-256 hash for $ExpectedPackageMoniker`: $rawHash"
  }

  if ($bytes.Length -ne 32) {
    throw "Unexpected decoded catalog SHA-256 byte length ($($bytes.Length)) for $ExpectedPackageMoniker."
  }

  return [Convert]::ToHexString($bytes).ToLowerInvariant()
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

dotnet --info

$windowsPackages = @()

if ($ManifestPath) {
  if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Probe manifest not found: $ManifestPath"
  }

  $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
  $architectures = $manifest.sources.windows.architectures
  if ($architectures) {
    foreach ($property in $architectures.PSObject.Properties) {
      $entry = $property.Value
      if ($entry.downloadable -eq $true) {
        if (-not $entry.packageMoniker) {
          throw "Probe manifest has downloadable Windows $($property.Name) entry without packageMoniker."
        }
        if (-not $entry.packageMoniker.StartsWith("$PackageIdentity`_", [StringComparison]::OrdinalIgnoreCase)) {
          throw "Probe manifest Windows $($property.Name) package does not match identity $PackageIdentity`: $($entry.packageMoniker)."
        }
        $isRequired = ($property.Name -eq "x64" -or $RequireArm64.IsPresent)
        $expectedSha256 = Resolve-ExpectedCatalogSha256 -Catalog $entry.catalog -ExpectedPackageMoniker $entry.packageMoniker
        $windowsPackages += [pscustomobject]@{
          Architecture = $property.Name
          ExpectedPackageMoniker = $entry.packageMoniker
          ExpectedContentLength = [int64] ($entry.contentLength ?? 0)
          ExpectedSha256 = $expectedSha256
          Required = $isRequired
        }
      }
    }
  }

  if ($windowsPackages.Count -eq 0 -and $manifest.sources.windows.packageMoniker) {
    $windowsPackages += [pscustomobject]@{
      Architecture = "x64"
      ExpectedPackageMoniker = $manifest.sources.windows.packageMoniker
      ExpectedContentLength = [int64] ($manifest.sources.windows.contentLength ?? 0)
      ExpectedSha256 = ""
      Required = $true
    }
  }

  if ($windowsPackages.Count -eq 0) {
    throw "Probe manifest is missing sources.windows.packageMoniker"
  }
} else {
  $windowsPackages += [pscustomobject]@{
    Architecture = "x64"
    ExpectedPackageMoniker = $null
    ExpectedContentLength = 0
    ExpectedSha256 = ""
    Required = $true
  }
}

function Resolve-StorePackageLink {
  param(
    [string] $Architecture,
    [string] $ExpectedPackageMoniker,
    [bool] $Required = $true
  )

  $lastError = "No Microsoft Store package link was resolved."

  for ($attempt = 1; $attempt -le $StoreLinkMaxAttempts; $attempt++) {
    Write-Host "Resolving Microsoft Store $Architecture package link (attempt $attempt/$StoreLinkMaxAttempts)"

    $resolverOutput = & dotnet run --project scripts/store-link -- $ProductId $Architecture $PackageIdentity
    if ($LASTEXITCODE -ne 0) {
      $lastError = "Microsoft Store resolver failed with exit code $LASTEXITCODE."
    } else {
      $expectedPrefix = "$PackageIdentity`_"
      $linkLine = $resolverOutput |
        Where-Object { $_.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1

      if (-not $linkLine) {
        $lastError = "No Microsoft Store package link was resolved."
      } else {
        $parts = $linkLine -split "`t", 2
        if ($parts.Count -lt 2 -or -not $parts[1]) {
          $lastError = "Microsoft Store package link is malformed: $linkLine"
        } else {
          $packageMoniker = $parts[0]
          $downloadUrl = $parts[1]

          if ($ExpectedPackageMoniker -and $packageMoniker -ne $ExpectedPackageMoniker) {
            $lastError = "Microsoft Store package changed after probe. Expected $ExpectedPackageMoniker, got $packageMoniker."
            if (-not $Required) {
              Write-Warning "$lastError Skipping optional Windows $Architecture package for this run."
              return $null
            }
          } else {
            return [pscustomobject]@{
              PackageMoniker = $packageMoniker
              DownloadUrl = $downloadUrl
            }
          }
        }
      }
    }

    if ($attempt -lt $StoreLinkMaxAttempts) {
      Write-Warning "$lastError Retrying in $StoreLinkRetryDelaySeconds seconds."
      if ($StoreLinkRetryDelaySeconds -gt 0) {
        Start-Sleep -Seconds $StoreLinkRetryDelaySeconds
      }
    }
  }

  if (-not $Required) {
    Write-Warning "$lastError Skipping optional Windows $Architecture package for this run."
    return $null
  }

  throw $lastError
}

$downloadedChecksumLines = @()
foreach ($windowsPackage in $windowsPackages) {
  $resolvedPackage = Resolve-StorePackageLink `
    -Architecture $windowsPackage.Architecture `
    -ExpectedPackageMoniker $windowsPackage.ExpectedPackageMoniker `
    -Required $windowsPackage.Required
  if ($null -eq $resolvedPackage) {
    continue
  }

  $downloadedOk = $false
  $lastDownloadError = $null

  for ($downloadAttempt = 1; $downloadAttempt -le $DownloadMaxAttempts; $downloadAttempt++) {
    if ($downloadAttempt -gt 1) {
      $resolvedPackage = Resolve-StorePackageLink `
        -Architecture $windowsPackage.Architecture `
        -ExpectedPackageMoniker $windowsPackage.ExpectedPackageMoniker `
        -Required $windowsPackage.Required
      if ($null -eq $resolvedPackage) {
        break
      }
    }

    $packageMoniker = $resolvedPackage.PackageMoniker
    $downloadUrl = $resolvedPackage.DownloadUrl
    $target = Join-Path $OutDir "$packageMoniker.Msix"

    try {
      Write-Host "Downloading $packageMoniker (attempt $downloadAttempt/$DownloadMaxAttempts)"
      Write-Host "Resolved Microsoft CDN URL: $downloadUrl"

      Invoke-WebRequest `
        -Uri $downloadUrl `
        -OutFile $target `
        -MaximumRedirection 5

      if ($windowsPackage.ExpectedContentLength -gt 0) {
        $actualLength = (Get-Item -LiteralPath $target).Length
        if ($actualLength -ne $windowsPackage.ExpectedContentLength) {
          throw "Downloaded size mismatch for $target. Expected $($windowsPackage.ExpectedContentLength) bytes, got $actualLength bytes."
        }
      }

      $actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
      if ($windowsPackage.ExpectedSha256 -and $actualSha256 -ne $windowsPackage.ExpectedSha256) {
        throw "Downloaded SHA-256 mismatch for $target against DisplayCatalog hash. Expected $($windowsPackage.ExpectedSha256), got $actualSha256."
      }

      $downloadedChecksumLines += "$actualSha256  $(Split-Path -Leaf $target)"
      $downloadedOk = $true
      break
    } catch {
      $lastDownloadError = $_
      Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue

      if ($downloadAttempt -lt $DownloadMaxAttempts) {
        Write-Warning "Windows $($windowsPackage.Architecture) download/verification failed (attempt $downloadAttempt/$DownloadMaxAttempts): $($_.Exception.Message) Retrying in $DownloadRetryDelaySeconds seconds."
        if ($DownloadRetryDelaySeconds -gt 0) {
          Start-Sleep -Seconds $DownloadRetryDelaySeconds
        }
      }
    }
  }

  if (-not $downloadedOk) {
    if ($null -eq $resolvedPackage -or -not $windowsPackage.Required) {
      if ($null -ne $lastDownloadError) {
        Write-Warning "Skipping optional Windows $($windowsPackage.Architecture) package after $DownloadMaxAttempts failed download attempts: $($lastDownloadError.Exception.Message)"
      }
      continue
    }
    throw $lastDownloadError
  }
}

if ($downloadedChecksumLines.Count -eq 0) {
  throw "No Windows packages were downloaded."
}

$downloadedChecksumLines |
  Set-Content -Encoding ascii -Path (Join-Path $OutDir "SHA256SUMS-windows.txt")
