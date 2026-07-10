param(
  [string] $OutDir = "dist",
  [string] $ManifestPath = "",
  [string] $ProductId = "9PLM9XGG6VKS",
  [string] $PackageIdentity = "OpenAI.Codex",
  [switch] $RequireArm64,
  [int] $StoreLinkMaxAttempts = 12,
  [int] $StoreLinkRetryDelaySeconds = 30
)

$ErrorActionPreference = "Stop"

if ($StoreLinkMaxAttempts -lt 1) {
  throw "StoreLinkMaxAttempts must be at least 1."
}

if ($StoreLinkRetryDelaySeconds -lt 0) {
  throw "StoreLinkRetryDelaySeconds must be non-negative."
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
        $windowsPackages += [pscustomobject]@{
          Architecture = $property.Name
          ExpectedPackageMoniker = $entry.packageMoniker
          ExpectedContentLength = [int64] ($entry.contentLength ?? 0)
          Required = ($property.Name -eq "x64" -or $RequireArm64.IsPresent)
        }
      }
    }
  }

  if ($windowsPackages.Count -eq 0 -and $manifest.sources.windows.packageMoniker) {
    $windowsPackages += [pscustomobject]@{
      Architecture = "x64"
      ExpectedPackageMoniker = $manifest.sources.windows.packageMoniker
      ExpectedContentLength = [int64] ($manifest.sources.windows.contentLength ?? 0)
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

$downloadedTargets = @()
foreach ($windowsPackage in $windowsPackages) {
  $resolvedPackage = Resolve-StorePackageLink `
    -Architecture $windowsPackage.Architecture `
    -ExpectedPackageMoniker $windowsPackage.ExpectedPackageMoniker `
    -Required $windowsPackage.Required
  if ($null -eq $resolvedPackage) {
    continue
  }

  $packageMoniker = $resolvedPackage.PackageMoniker
  $downloadUrl = $resolvedPackage.DownloadUrl

  $target = Join-Path $OutDir "$packageMoniker.Msix"

  Write-Host "Downloading $packageMoniker"
  Write-Host "Resolved Microsoft CDN URL: $downloadUrl"

  Invoke-WebRequest `
    -Uri $downloadUrl `
    -OutFile $target `
    -MaximumRedirection 5

  if ($windowsPackage.ExpectedContentLength -gt 0) {
    $actualLength = (Get-Item -LiteralPath $target).Length
    if ($actualLength -ne $windowsPackage.ExpectedContentLength) {
      if (-not $windowsPackage.Required) {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        Write-Warning "Downloaded size mismatch for optional Windows $($windowsPackage.Architecture) package. Expected $($windowsPackage.ExpectedContentLength) bytes, got $actualLength bytes. Skipping this optional package for this run."
        continue
      }
      throw "Downloaded size mismatch for $target. Expected $($windowsPackage.ExpectedContentLength) bytes, got $actualLength bytes."
    }
  }

  $downloadedTargets += $target
}

if ($downloadedTargets.Count -eq 0) {
  throw "No Windows packages were downloaded."
}

Get-FileHash -Algorithm SHA256 -Path $downloadedTargets |
  ForEach-Object { "$($_.Hash.ToLowerInvariant())  $(Split-Path -Leaf $_.Path)" } |
  Set-Content -Encoding ascii -Path (Join-Path $OutDir "SHA256SUMS-windows.txt")
