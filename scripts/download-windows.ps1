param(
  [string] $OutDir = "dist"
)

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

dotnet --info

$linkLine = dotnet run --project scripts/store-link -- 9PLM9XGG6VKS x64 |
  Where-Object { $_ -match "^OpenAI\.Codex_" } |
  Select-Object -First 1

if (-not $linkLine) {
  throw "No Microsoft Store package link was resolved."
}

$parts = $linkLine -split "`t", 2
$packageMoniker = $parts[0]
$downloadUrl = $parts[1]
$target = Join-Path $OutDir "$packageMoniker.Msix"

Write-Host "Downloading $packageMoniker"
Write-Host "Resolved Microsoft CDN URL: $downloadUrl"

Invoke-WebRequest `
  -Uri $downloadUrl `
  -OutFile $target `
  -MaximumRedirection 5

Get-FileHash -Algorithm SHA256 -Path $target |
  ForEach-Object { "$($_.Hash.ToLowerInvariant())  $(Split-Path -Leaf $_.Path)" } |
  Set-Content -Encoding ascii -Path (Join-Path $OutDir "SHA256SUMS-windows.txt")
