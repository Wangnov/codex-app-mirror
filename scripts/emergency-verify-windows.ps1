param(
  [Parameter(Mandatory = $true)]
  [string] $ManifestPath,
  [string] $ArtifactsDir = "dist/windows",
  [string] $OutputPath = "dist/windows/windows-identity.json"
)

$ErrorActionPreference = "Stop"
$expectedIdentity = "OpenAI.Codex"
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$packages = Get-ChildItem -LiteralPath $ArtifactsDir -File |
  Where-Object { $_.Name -match '\.(Msix|msix)$' } |
  Sort-Object Name

if ($packages.Count -ne 2) {
  throw "Expected exactly two Stable MSIX packages, found $($packages.Count)."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$architectures = [ordered]@{}

foreach ($package in $packages) {
  if ($package.Name -match '_x64__') {
    $architecture = 'x64'
  } elseif ($package.Name -match '_arm64__') {
    $architecture = 'arm64'
  } else {
    throw "Cannot determine architecture from $($package.Name)."
  }

  $expected = $manifest.sources.windows.architectures.$architecture
  if (-not $expected -or $expected.downloadable -ne $true) {
    throw "Probe manifest does not advertise downloadable Windows $architecture."
  }
  if ($package.BaseName -ne $expected.packageMoniker) {
    throw "Windows $architecture package drift: expected $($expected.packageMoniker), got $($package.BaseName)."
  }
  if ($package.Length -ne [int64]$expected.contentLength) {
    throw "Windows $architecture size mismatch: expected $($expected.contentLength), got $($package.Length)."
  }

  $archive = [System.IO.Compression.ZipFile]::OpenRead($package.FullName)
  try {
    $manifestEntries = @($archive.Entries | Where-Object {
      $_.FullName.Replace('\', '/').ToLowerInvariant() -eq 'appxmanifest.xml'
    })
    if ($manifestEntries.Count -ne 1) {
      throw "$($package.Name) must contain exactly one root AppxManifest.xml; found $($manifestEntries.Count)."
    }

    $stream = $manifestEntries[0].Open()
    try {
      $document = [System.Xml.Linq.XDocument]::Load($stream)
    } finally {
      $stream.Dispose()
    }

    $ns = $document.Root.Name.Namespace
    $identity = $document.Root.Element($ns + 'Identity')
    if ($null -eq $identity) {
      throw "$($package.Name) has no Package/Identity element."
    }
    $identityName = $identity.Attribute('Name').Value
    $packageVersion = $identity.Attribute('Version').Value
    $processorArchitecture = $identity.Attribute('ProcessorArchitecture').Value.ToLowerInvariant()
    if ($identityName -ne $expectedIdentity) {
      throw "$($package.Name) identity mismatch: expected=$expectedIdentity actual=$identityName."
    }
    if ($packageVersion -ne $expected.version) {
      throw "$($package.Name) package version mismatch: expected=$($expected.version) actual=$packageVersion."
    }
    if ($processorArchitecture -ne $architecture) {
      throw "$($package.Name) processor architecture mismatch: expected=$architecture actual=$processorArchitecture."
    }

    $applicationsNode = $document.Root.Element($ns + 'Applications')
    $applications = if ($null -eq $applicationsNode) { @() } else { @($applicationsNode.Elements($ns + 'Application')) }
    if ($applications.Count -ne 1) {
      throw "$($package.Name) must contain exactly one Application entry; found $($applications.Count)."
    }
    $applicationId = $applications[0].Attribute('Id').Value
    $executable = $applications[0].Attribute('Executable').Value.Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($executable)) {
      throw "$($package.Name) Application@Executable is empty."
    }

    $matchingExecutables = @($archive.Entries | Where-Object {
      $_.FullName.Replace('\', '/').Equals($executable, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($matchingExecutables.Count -ne 1) {
      throw "$($package.Name) manifest executable '$executable' does not resolve to exactly one package entry."
    }

    $sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $package.FullName).Hash.ToLowerInvariant()
    $architectures[$architecture] = [ordered]@{
      architecture = $architecture
      fileName = $package.Name
      sha256 = $sha256
      packageIdentity = $identityName
      packageVersion = $packageVersion
      packageFamilyName = [string]$expected.catalog.packageFamilyName
      applicationId = $applicationId
      applicationExecutable = $executable
    }
    Write-Host "$($package.Name) passed Stable identity gate: $identityName / $applicationId / $executable"
  } finally {
    $archive.Dispose()
  }
}

if (-not $architectures.Contains('x64') -or -not $architectures.Contains('arm64')) {
  throw "Verified MSIX set is missing x64 or arm64."
}

$payload = [ordered]@{
  schemaVersion = 1
  channel = 'stable'
  expectedIdentity = $expectedIdentity
  architectures = $architectures
}

$parent = Split-Path -Parent $OutputPath
if ($parent) {
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
}
$payload | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 -LiteralPath $OutputPath
Get-Content -LiteralPath $OutputPath
