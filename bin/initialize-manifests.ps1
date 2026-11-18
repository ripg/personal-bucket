$ErrorActionPreference = 'Stop'

$headers = @{
    Accept = 'application/vnd.github+json'
    Authorization = "Bearer $env:GITHUB_TOKEN"
}
$bucket = Join-Path $PSScriptRoot '../bucket'

function Get-ArchiveInfo($asset, $exePattern) {
    $archive = New-TemporaryFile
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archive.FullName
        $hash = (Get-FileHash -LiteralPath $archive.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($asset.digest -and $asset.digest -ne "sha256:$hash") {
            throw "SHA-256 mismatch for $($asset.name)."
        }
        $zip = [IO.Compression.ZipFile]::OpenRead($archive.FullName)
        try {
            $entries = @($zip.Entries | Where-Object { $_.Name -match $exePattern })
            if ($entries.Count -ne 1) { throw "Expected one application executable in $($asset.name)." }
            $entry = $entries[0]
            $parent = $entry.FullName.Substring(0, $entry.FullName.Length - $entry.Name.Length).TrimEnd('/')
            return @{ hash = $hash; exe = $entry.Name; directory = $parent.Replace('/', '\') }
        } finally {
            $zip.Dispose()
        }
    } finally {
        Remove-Item -LiteralPath $archive.FullName
    }
}

function New-Manifest($name, $manifest, $targets, $release, $exePattern) {
    $manifest.architecture = [ordered]@{}
    foreach ($target in $targets.GetEnumerator()) {
        $assets = @($release.assets | Where-Object { $_.browser_download_url -eq $target.Value })
        if ($assets.Count -ne 1) { throw "Missing upstream Windows ZIP: $($target.Value)" }
        $info = Get-ArchiveInfo $assets[0] $exePattern
        $architecture = [ordered]@{
            url = $target.Value
            hash = $info.hash
        }
        if ($info.directory) { $architecture.extract_dir = $info.directory }
        $architecture.shortcuts = ,@($info.exe, $manifest.shortcutName)
        $manifest.architecture[$target.Key] = $architecture
    }
    $manifest.Remove('shortcutName')
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $bucket "$name.json") -Encoding utf8
}

if (-not (Test-Path -LiteralPath (Join-Path $bucket 'tx-5dr.json'))) {
    $release = Invoke-RestMethod -Headers $headers -Uri 'https://api.github.com/repos/boybook/tx-5dr/releases/latest'
    if ($release.tag_name -notmatch '^v(\d+(?:\.\d+)+)$') { throw "Unexpected TX-5DR tag: $($release.tag_name)" }
    $version = $Matches[1]
    $url = 'https://github.com/boybook/tx-5dr/releases/download/v$version/TX-5DR-v$version-windows-x64.zip'
    $manifest = [ordered]@{
        version = $version
        description = 'Amateur radio digital modes desktop application.'
        homepage = 'https://github.com/boybook/tx-5dr'
        shortcutName = 'TX-5DR'
        checkver = @{
            url = 'https://api.github.com/repos/boybook/tx-5dr/releases/latest'
            jsonpath = '$.tag_name'
            regex = '^v([\d.]+)$'
        }
        autoupdate = @{ architecture = @{ '64bit' = @{ url = $url } } }
    }
    New-Manifest 'tx-5dr' $manifest @{ '64bit' = $url.Replace('$version', $version) } $release '^TX[- ]?5DR\.exe$'
}

if (-not (Test-Path -LiteralPath (Join-Path $bucket 'qft8.json'))) {
    $source = 'https://qft8.com/zh/'
    $regex = 'qFT8-v([\d.]+)-windows-64bits\.zip'
    $page = Invoke-WebRequest -Uri $source
    if ($page.Content -notmatch $regex) { throw 'Cannot find the qFT8 Windows version.' }
    $version = $Matches[1]
    $release = Invoke-RestMethod -Headers $headers -Uri 'https://api.github.com/repos/lquesada/qFT8/releases/tags/main'
    $base = 'https://github.com/lquesada/qFT8/releases/download/main/qFT8-v$version-windows-'
    $urls = [ordered]@{
        '64bit' = "$($base)64bits.zip"
        '32bit' = "$($base)32bits.zip"
    }
    $manifest = [ordered]@{
        version = $version
        description = 'Amateur radio application for FT8 and other digital modes.'
        homepage = $source
        shortcutName = 'qFT8'
        license = 'Freeware'
        checkver = @{ url = $source; regex = $regex }
        autoupdate = @{ architecture = @{
            '64bit' = @{ url = $urls['64bit'] }
            '32bit' = @{ url = $urls['32bit'] }
        } }
    }
    $targets = [ordered]@{
        '64bit' = $urls['64bit'].Replace('$version', $version)
        '32bit' = $urls['32bit'].Replace('$version', $version)
    }
    New-Manifest 'qft8' $manifest $targets $release '^qFT8\.exe$'
}

if (-not (Test-Path -LiteralPath (Join-Path $bucket 'gridtracker2.json'))) {
    $source = 'https://gridtracker.org/index.php/downloads/gridtracker-downloads'
    $regex = 'https://download2\.gridtracker\.org/GridTracker2-([\d.]+)-setup\.exe'
    $page = Invoke-WebRequest -Uri $source
    if ($page.Content -notmatch $regex) { throw 'Cannot find the GridTracker2 Windows installer.' }
    $version = $Matches[1]
    $download = $Matches[0]
    $temp = New-Item -ItemType Directory -Path (Join-Path $env:RUNNER_TEMP "gridtracker2-$([guid]::NewGuid())")
    try {
        $installer = Join-Path $temp.FullName 'setup.exe'
        Invoke-WebRequest -Uri $download -OutFile $installer
        $hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
        $sevenZip = Join-Path $env:ProgramFiles '7-Zip/7z.exe'
        & $sevenZip x $installer "-o$($temp.FullName)" '-y' '$PLUGINSDIR\app-*.7z' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not extract the GridTracker2 installer.' }

        $architecture = [ordered]@{}
        $exeName = 'GridTracker2.exe'
        foreach ($bits in '64', '32') {
            $archiveName = "app-$bits.7z"
            $payload = Join-Path $temp.FullName ('$PLUGINSDIR/' + $archiveName)
            if (-not (Test-Path -LiteralPath $payload)) { continue }
            $entries = & $sevenZip l -slt $payload
            if ($LASTEXITCODE -ne 0 -or $entries -notcontains "Path = $exeName") {
                throw "Could not find $exeName in $archiveName."
            }
            $architecture["$($bits)bit"] = @{
                pre_install = ('Expand-7zipArchive "$dir\`$PLUGINSDIR\{0}" "$dir"' -f $archiveName)
            }
        }
        if (-not $architecture['64bit']) { throw 'GridTracker2 installer lacks an x64 payload.' }

        $manifest = [ordered]@{
            version = $version
            description = 'Amateur radio grid mapping and logging companion for WSJT-X and JTDX.'
            homepage = 'https://gridtracker.org/'
            license = 'BSD-3-Clause'
            url = "$download#/dl.7z"
            hash = $hash
            architecture = $architecture
            post_install = 'Get-Item "$dir\`$PLUGINSDIR", "$dir\`$R0" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force'
            shortcuts = ,@($exeName, 'GridTracker2', '--disable-auto-updates')
            checkver = @{ url = $source; regex = $regex }
            autoupdate = @{ url = 'https://download2.gridtracker.org/GridTracker2-$version-setup.exe#/dl.7z' }
        }
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $bucket 'gridtracker2.json') -Encoding utf8
    } finally {
        Remove-Item -LiteralPath $temp.FullName -Recurse -Force
    }
}
