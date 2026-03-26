param(
    [Parameter(Mandatory = $true)]
    [string[]]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Update-ArchitectureNode {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Node,
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [Parameter()]
        [string]$Hash,
        [Parameter()]
        [switch]$UpdateHash
    )

    if ($Node.PSObject.Properties.Name -notcontains 'url') {
        return
    }

    $Node.url = $Url

    if ($UpdateHash -and $Node.PSObject.Properties.Name -contains 'hash') {
        $Node.hash = $Hash
    }
}

foreach ($path in $ManifestPath) {
    $resolvedPath = Resolve-Path -Path $path
    $manifest = Get-Content -Path $resolvedPath -Raw | ConvertFrom-Json

    if (-not $manifest.checkver) {
        continue
    }

    if ($manifest.checkver -notmatch '^https://pypi\.org/pypi/(?<package>[^/]+)/json$') {
        continue
    }

    $packageName = $Matches.package
    $version = [string]$manifest.version

    $pypiResponse = Invoke-RestMethod -Uri $manifest.checkver
    $releaseFiles = @($pypiResponse.releases.$version)

    if (-not $releaseFiles -or $releaseFiles.Count -eq 0) {
        throw "No PyPI release files found for $packageName $version"
    }

    $sdist = $releaseFiles | Where-Object { $_.packagetype -eq 'sdist' } | Select-Object -First 1

    if (-not $sdist) {
        throw "No source distribution found for $packageName $version"
    }

    $sdistFileName = [string]$sdist.filename
    $versionMarker = "-$version"
    $versionIndex = $sdistFileName.LastIndexOf($versionMarker)

    if ($versionIndex -le 0) {
        throw "Unable to derive distribution name from sdist filename '$sdistFileName' for version '$version'"
    }

    $distributionName = $sdistFileName.Substring(0, $versionIndex)
    $firstLetter = $distributionName.Substring(0, 1).ToLowerInvariant()
    $autoupdateFileName = $sdistFileName.Substring(0, $versionIndex + 1) + '$version' + $sdistFileName.Substring($versionIndex + 1 + $version.Length)

    $manifestUrl = "https://files.pythonhosted.org/packages/source/$firstLetter/$distributionName/$sdistFileName"
    $autoupdateUrl = "https://files.pythonhosted.org/packages/source/$firstLetter/$distributionName/$autoupdateFileName"

    if ($manifest.architecture) {
        foreach ($architectureProperty in $manifest.architecture.PSObject.Properties) {
            Update-ArchitectureNode -Node $architectureProperty.Value -Url $manifestUrl -Hash $sdist.digests.sha256 -UpdateHash
        }
    }

    if ($manifest.autoupdate -and $manifest.autoupdate.architecture) {
        foreach ($architectureProperty in $manifest.autoupdate.architecture.PSObject.Properties) {
            Update-ArchitectureNode -Node $architectureProperty.Value -Url $autoupdateUrl
        }
    }

    $compactJson = $manifest | ConvertTo-Json -Depth 20 -Compress
    $compactJson | python -c "import json, pathlib, sys; pathlib.Path(sys.argv[1]).write_text(json.dumps(json.load(sys.stdin), indent=2) + '\n', encoding='utf-8')" $resolvedPath
}