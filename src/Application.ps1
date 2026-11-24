function Resolve-CncDirectoryPath {
    param([string]$Path)

    $provider = $null
    $drive = $null
    $filePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $Path, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') { throw "Not a filesystem directory: '$Path'." }
    return [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($filePath))
}

function Assert-CncDirectoryPath {
    param([string]$Path)

    for ($directory = [IO.DirectoryInfo]::new($Path); $null -ne $directory; $directory = $directory.Parent) {
        try { $item = Get-Item -LiteralPath $directory.FullName -Force -ErrorAction Stop }
        catch [System.Management.Automation.ItemNotFoundException] { continue }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Unsafe filesystem path: '$($directory.FullName)' is a symbolic link, junction, or other reparse point."
        }
        if (-not $item.PSIsContainer) { throw "Not a filesystem directory: '$($directory.FullName)'." }
    }
}

function Move-CncOutputDirectory {
    param([string]$From, [string]$To)

    [IO.Directory]::Move($From, $To)
}

function Remove-CncWorkDirectory {
    param([string]$Path)

    try {
        Assert-CncDirectoryPath $Path
        if ([IO.Directory]::Exists($Path)) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        }
    } catch { Write-Warning "Could not remove temporary directory '$Path': $($_.Exception.Message)" }
}

function Assert-CncOutputOwnership {
    param([string]$Path)

    $existingItem = Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1
    if ($null -eq $existingItem) { return }
    $markerPath = Join-Path $Path '.cnc-output'
    $marker = Get-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $marker -or $marker.PSIsContainer -or
        ($marker.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        [IO.File]::ReadAllText($markerPath) -cne 'CNC-Stage3 managed output v1') {
        throw "Output directory '$Path' is nonempty and is not managed by CNC. Use an empty directory or specify -ReplaceExistingOutput to replace it."
    }
}

function Publish-CncBatch {
    param([string]$OutputFolder, [object[]]$Generated, [switch]$ReplaceExistingOutput)

    $parent = [IO.Path]::GetDirectoryName($OutputFolder)
    $name = [IO.Path]::GetFileName($OutputFolder)
    if ($IsWindows) { $name = $name.ToUpperInvariant() }
    $nameHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($name)))
    $prefix = '.cnc-' + $nameHash.Substring(0, 16)
    $token = [guid]::NewGuid().ToString('N')
    $lockPath = Join-Path $parent "$prefix.lock"
    $stageFolder = Join-Path $parent "$prefix-$token.stage"
    $backupFolder = Join-Path $parent "$prefix-$token.backup"

    Assert-CncDirectoryPath $OutputFolder
    [void][IO.Directory]::CreateDirectory($parent)
    Assert-CncDirectoryPath $OutputFolder
    try {
        $lock = [IO.FileStream]::new($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
    } catch {
        throw "Could not lock output '$OutputFolder'. Check '$lockPath' and retry after any active generation finishes. $($_.Exception.Message)"
    }

    $stageCreated = $false
    try {
        $leftoverBackups = @(Get-ChildItem -LiteralPath $parent -Force -Filter "$prefix-*.backup")
        if ($leftoverBackups.Count -gt 0) {
            $paths = $leftoverBackups.FullName -join ', '
            throw "Recover or move the previous output backup before publishing to '$OutputFolder': $paths"
        }
        Assert-CncDirectoryPath $OutputFolder
        $hadOutput = [IO.Directory]::Exists($OutputFolder)
        if ($hadOutput -and -not $ReplaceExistingOutput) { Assert-CncOutputOwnership $OutputFolder }
        [void](New-Item -ItemType Directory -Path $stageFolder)
        $stageCreated = $true
        foreach ($item in $Generated) {
            $stagePath = Join-Path $stageFolder $item.OutputName
            Write-CncDxfOutput -Item $item -Path $stagePath
            [void](Test-GeneratedDxf -File (Get-Item -LiteralPath $stagePath) -Plan $item)
        }
        $stageMarker = Join-Path $stageFolder '.cnc-output'
        [IO.File]::WriteAllText($stageMarker, 'CNC-Stage3 managed output v1')
        if ($IsWindows) { [IO.File]::SetAttributes($stageMarker, [IO.FileAttributes]::Hidden) }

        Assert-CncDirectoryPath $OutputFolder
        if ($hadOutput) {
            if (-not $ReplaceExistingOutput) { Assert-CncOutputOwnership $OutputFolder }
            Move-CncOutputDirectory -From $OutputFolder -To $backupFolder
        }
        try {
            Move-CncOutputDirectory -From $stageFolder -To $OutputFolder
            $stageCreated = $false
        } catch {
            $publishError = $_.Exception.Message
            if (-not $hadOutput) { throw "Could not publish output to '$OutputFolder': $publishError" }
            try { Move-CncOutputDirectory -From $backupFolder -To $OutputFolder }
            catch {
                throw "Could not restore '$OutputFolder'. Previous output remains at '$backupFolder'. Publish error: $publishError. Restore error: $($_.Exception.Message)"
            }
            throw "Could not publish output to '$OutputFolder'. Previous output was restored. $publishError"
        }
        if ($hadOutput) { Remove-CncWorkDirectory $backupFolder }
    } finally {
        try {
            if ($stageCreated) { Remove-CncWorkDirectory $stageFolder }
        } finally { $lock.Dispose() }
    }
}

function Invoke-CncBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$OutputFolder,
        [switch]$ValidateOnly,
        [switch]$ReplaceExistingOutput
    )
    $ErrorActionPreference = 'Stop'
    $SourceFolder = Resolve-CncDirectoryPath $SourceFolder
    $OutputFolder = Resolve-CncDirectoryPath $OutputFolder
    $desktop = [Environment]::GetFolderPath('Desktop')
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $rootPath = [IO.Path]::GetPathRoot($OutputFolder)
    $outputPrefix = $OutputFolder + [IO.Path]::DirectorySeparatorChar
    if ($OutputFolder.Equals([IO.Path]::TrimEndingDirectorySeparator($rootPath), $comparison) -or
        $SourceFolder.Equals($OutputFolder, $comparison) -or $SourceFolder.StartsWith($outputPrefix, $comparison) -or
        ($desktop -and ($desktop.Equals($OutputFolder, $comparison) -or $desktop.StartsWith($outputPrefix, $comparison)))) {
        throw 'Unsafe output path: output must not be a filesystem root, the input folder, Desktop, or an ancestor of these folders.'
    }
    Assert-CncDirectoryPath $SourceFolder
    Assert-CncDirectoryPath $OutputFolder
try {
    Write-Host ''
    Write-Host '=== Independent DXF Generator for CNC Parts ===' -ForegroundColor Cyan
    Write-Host "Input: $sourceFolder"
    Write-Host "Output: $outputFolder"
    if (-not (Test-Path -LiteralPath $sourceFolder -PathType Container)) { throw "Input folder not found: $sourceFolder" }
    $files = @(Get-ChildItem -LiteralPath $sourceFolder -File | Where-Object { $_.Extension -match '^\.dxf$' } | Sort-Object Name)
    if ($files.Count -eq 0) { throw "No DXF files found in folder $sourceFolder." }
    Write-Host "Number of input files: $($files.Count)" -ForegroundColor Cyan

    $documents = [System.Collections.Generic.List[object]]::new(); $validationErrors = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $files) {
        Write-Host "`n[Validating] $($file.Name)" -ForegroundColor Yellow
        try {
            $doc = Read-DxfDocument $file
            $doc = Build-DxfPlan $doc
            $documents.Add($doc)
        } catch {
            $message = "$($file.Name): $($_.Exception.Message)"
            $validationErrors.Add($message)
            Write-Host "  Error: $message" -ForegroundColor Red
        }
    }
    if ($validationErrors.Count -eq 0) {
        try { Resolve-GlobalPairs -Documents $documents.ToArray() }
        catch {
            $message = "Global SH+Z pairing: $($_.Exception.Message)"
            $validationErrors.Add($message)
            Write-Host "  Error: $message" -ForegroundColor Red
        }
    }
    if ($validationErrors.Count -gt 0) {
        Write-Host "`nGeneration stopped; no new output files were written and existing files in folder B were preserved." -ForegroundColor Red
        foreach ($message in $validationErrors) { Write-Host " - $message" -ForegroundColor Red }
        throw 'Validation failed for one or more input files.'
    }
    if ($validationErrors.Count -eq 0) {
        try { Assert-CncGeometry -Documents $documents.ToArray() }
        catch {
            $message = "Geometry validation: $($_.Exception.Message)"
            $validationErrors.Add($message)
            Write-Host "  Error: $message" -ForegroundColor Red
            Write-Host "`nGeneration stopped; geometry check failed; folder B was not changed." -ForegroundColor Red
            throw 'Geometry safety validation failed.'
        }
    }
    foreach ($doc in $documents) {
        Write-Host "  Detected OptiCut format: $($doc.OptiCutFormat) ($($doc.File.Name))" -ForegroundColor DarkCyan
        Write-Host "  Verified $($doc.File.Name): parts $($doc.Stats.PartCount), dimension TEXT checked $($doc.Stats.DimensionCount), feature labels $($doc.Stats.FeatureCount), pairs $($doc.Stats.PairCount), grooves $($doc.Stats.GrooveCount), handle notches $($doc.Stats.HandleCount)" -ForegroundColor Green
        foreach ($mark in $doc.FeatureRecords) {
            $actionParts = [System.Collections.Generic.List[string]]::new()
            if ($mark.HasSH) { $actionParts.Add("Groove $($mark.GrooveEdge), offset $($mark.GrooveOffset) mm") }
            if ($mark.HasZ) { $actionParts.Add("Notch $($mark.Corner); edges $($mark.HandleEdges -join '+')") }
            $mapping = if ($mark.IsPair) { "$($mark.State)/$($mark.Role)" } else { "Standalone/$($mark.Shape.Orientation)" }
            Write-Host "    $($mark.Label) | Handle $($mark.Shape.Handle) | $($mark.Shape.Width)x$($mark.Shape.Height) | Table $($mark.Table) | $mapping | $($actionParts -join '; ')" -ForegroundColor DarkCyan
        }
    }
    Write-Host "`nAll input files validated successfully; starting in-memory generation." -ForegroundColor Green

    $generated = [System.Collections.Generic.List[object]]::new()
    foreach ($doc in $documents) {
        try { $generated.Add((Apply-DxfPlan $doc)) }
        catch { throw "Error preparing output for '$($doc.File.Name)'; no output files have been written yet. Details: $($_.Exception.Message)" }
    }
    if ($ValidateOnly) {
        $verifyFolder = Join-Path ([System.IO.Path]::GetTempPath()) ('.dxf-verify-' + [guid]::NewGuid().ToString('N'))
        $verifyCreated = $false
        try {
            [void](New-Item -ItemType Directory -Path $verifyFolder)
            $verifyCreated = $true
            foreach ($item in $generated) {
                $verifyPath = Join-Path $verifyFolder $item.OutputName
                Write-CncDxfOutput -Item $item -Path $verifyPath
                [void](Test-GeneratedDxf -File (Get-Item -LiteralPath $verifyPath) -Plan $item)
            }
        } finally {
            if ($verifyCreated) { Remove-CncWorkDirectory $verifyFolder }
        }
        Write-Host "`nValidation, in-memory generation, and DXF round-trip verification succeeded; no files were written to B because ValidateOnly was specified." -ForegroundColor Green
        foreach ($item in $generated) { Write-Host "  $($item.Source.Name): handle notches $($item.NotchCount), groove lines $($item.SlotCount), DXF round-trip verification: passed" -ForegroundColor Green }
        return
    }

    Publish-CncBatch -OutputFolder $OutputFolder -Generated $generated.ToArray() -ReplaceExistingOutput:$ReplaceExistingOutput
    Write-Host "`n=== Generation Successful ===" -ForegroundColor Green
    foreach ($item in $generated) {
        Write-Host "  $($item.Source.Name) -> $(Join-Path $outputFolder $item.OutputName) | Parts: $($item.Stats.PartCount) | Handle notches: $($item.NotchCount) | Groove lines: $($item.SlotCount)" -ForegroundColor Green
    }
    Write-Host 'Input files in A were not modified. The OptiCut TXT output is also unchanged.' -ForegroundColor Green
    Write-Host ''
} catch {
    Write-Host "`nStopped: $($_.Exception.Message)" -ForegroundColor Red
    throw
}

}
