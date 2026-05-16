param(
  [string] $OutDir = "dist",
  [string] $ManifestPath = ""
)

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

dotnet --info

$expectedPackageMoniker = $null
$expectedContentLength = $null

if ($ManifestPath) {
  if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Probe manifest not found: $ManifestPath"
  }

  $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
  $expectedPackageMoniker = $manifest.sources.windows.packageMoniker
  $expectedContentLength = [int64] $manifest.sources.windows.contentLength

  if (-not $expectedPackageMoniker) {
    throw "Probe manifest is missing sources.windows.packageMoniker"
  }
}

$linkLine = dotnet run --project scripts/store-link -- 9PLM9XGG6VKS x64 |
  Where-Object { $_ -match "^OpenAI\.Codex_" } |
  Select-Object -First 1

if (-not $linkLine) {
  throw "No Microsoft Store package link was resolved."
}

$parts = $linkLine -split "`t", 2
$packageMoniker = $parts[0]
$downloadUrl = $parts[1]

if ($expectedPackageMoniker -and $packageMoniker -ne $expectedPackageMoniker) {
  throw "Microsoft Store package changed after probe. Expected $expectedPackageMoniker, got $packageMoniker."
}

$target = Join-Path $OutDir "$packageMoniker.Msix"

Write-Host "Downloading $packageMoniker"
Write-Host "Resolved Microsoft CDN URL: $downloadUrl"

Invoke-WebRequest `
  -Uri $downloadUrl `
  -OutFile $target `
  -MaximumRedirection 5

if ($expectedContentLength -gt 0) {
  $actualLength = (Get-Item -LiteralPath $target).Length
  if ($actualLength -ne $expectedContentLength) {
    throw "Downloaded size mismatch for $target. Expected $expectedContentLength bytes, got $actualLength bytes."
  }
}

Get-FileHash -Algorithm SHA256 -Path $target |
  ForEach-Object { "$($_.Hash.ToLowerInvariant())  $(Split-Path -Leaf $_.Path)" } |
  Set-Content -Encoding ascii -Path (Join-Path $OutDir "SHA256SUMS-windows.txt")
