$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Cnc.psm1') -Force -DisableNameChecking
$cncModule = Get-Module Cnc
$work = Join-Path $root ('tmp/preservation-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
$source = Join-Path $PSScriptRoot 'Sample_A_Valid'
$before = @(Get-ChildItem $source -File | Get-FileHash | Select-Object Path,Hash) | ConvertTo-Json -Compress

$output = Join-Path $work 'output'
[void](New-Item -ItemType Directory -Path (Join-Path $output 'old-subfolder') -Force)
Set-Content (Join-Path $output 'old-subfolder/sentinel.txt') 'preserve on validate; remove on generation'
Invoke-CncBatch -SourceFolder $source -OutputFolder $output -ValidateOnly 6>$null
if (!(Test-Path (Join-Path $output 'old-subfolder/sentinel.txt'))) { throw 'ValidateOnly changed existing output.' }
Invoke-CncBatch -SourceFolder $source -OutputFolder $output -ReplaceExistingOutput 6>$null
if (Test-Path (Join-Path $output 'old-subfolder')) { throw 'Normal generation did not clear prior output.' }
if (@(Get-ChildItem $output -File -Filter '*.dxf').Count -ne 10) { throw 'Normal generation did not produce all 10 DXF outputs.' }

$after = @(Get-ChildItem $source -File | Get-FileHash | Select-Object Path,Hash) | ConvertTo-Json -Compress
if ($before -cne $after) { throw 'Source DXF files changed.' }
Write-Host 'PASS ValidateOnly preserves old output; normal generation clears old subfolders; 10 outputs generated; inputs unchanged.'

$singleSource = Join-Path $work 'single-source'
[void](New-Item -ItemType Directory -Path $singleSource)
Copy-Item (Join-Path $PSScriptRoot 'TestFixtures/Legacy-One-Part.dxf') $singleSource
$missingOutput = Join-Path $work 'missing-output'
Invoke-CncBatch -SourceFolder $singleSource -OutputFolder $missingOutput -ValidateOnly 6>$null
if (Test-Path -LiteralPath $missingOutput) { throw 'ValidateOnly created a missing output directory.' }

Push-Location $work
try {
    foreach ($unsafePath in @('./single-source', '.')) {
        $caught = $null
        try { Invoke-CncBatch -SourceFolder $singleSource -OutputFolder $unsafePath -ValidateOnly 6>$null }
        catch { $caught = $_.Exception.Message }
        if ($caught -notlike 'Unsafe output path:*') { throw "Did not reject unsafe relative path '$unsafePath': $caught" }
    }
} finally { Pop-Location }
if ($IsWindows) {
    $alias = Join-Path $work 'source-junction'
    [void](New-Item -ItemType Junction -Path $alias -Target $singleSource)
    $caught = $null
    try { Invoke-CncBatch -SourceFolder $singleSource -OutputFolder (Join-Path $alias 'child') -ValidateOnly 6>$null }
    catch { $caught = $_.Exception.Message }
    if ($caught -notlike 'Unsafe filesystem path:*') { throw "Did not reject a junction in the output path: $caught" }
    $caught = $null
    try { Invoke-CncBatch -SourceFolder $alias -OutputFolder $missingOutput -ValidateOnly 6>$null }
    catch { $caught = $_.Exception.Message }
    if ($caught -notlike 'Unsafe filesystem path:*') { throw "Did not reject a junction as the source: $caught" }
}
Write-Host 'PASS Relative path aliases and Windows junction paths are rejected; validation does not create output.'

Set-Content (Join-Path $output 'stale.txt') 'remove automatically from a dedicated output'
Invoke-CncBatch -SourceFolder $singleSource -OutputFolder $output 6>$null
if ((Test-Path (Join-Path $output 'stale.txt')) -or
    @(Get-ChildItem -LiteralPath $output -File -Filter '*.dxf').Count -ne 1) {
    throw 'A managed output was not fully replaced without another opt-in.'
}

function Get-PreservationSnapshot {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Missing directory '$Path'." }
    @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
        [IO.Path]::GetRelativePath($Path, $_.FullName) + '|' + (Get-FileHash -LiteralPath $_.FullName).Hash
    }) -join "`n"
}

$protectedOutput = Join-Path $work 'existing-unmanaged'
[void](New-Item -ItemType Directory -Path (Join-Path $protectedOutput 'nested') -Force)
Set-Content (Join-Path $protectedOutput 'nested/sentinel.txt') 'unchanged on failure'
$expected = Get-PreservationSnapshot $protectedOutput
$caught = $null
try { Invoke-CncBatch -SourceFolder $singleSource -OutputFolder $protectedOutput 6>$null }
catch { $caught = $_.Exception.Message }
if ($caught -notlike '*-ReplaceExistingOutput*' -or (Get-PreservationSnapshot $protectedOutput) -cne $expected) {
    throw "Unmanaged output was not protected: $caught"
}

foreach ($failure in 'write', 'verify', 'publish', 'restore') {
    $caught = $null
    try {
        & $cncModule {
            param($InputPath, $OutputPath, $Failure)
            switch ($Failure) {
                'write' { function Write-CncDxfOutput { throw 'Injected staging write failure.' } }
                'verify' { function Test-GeneratedDxf { throw 'Injected staging verification failure.' } }
                default {
                    function Move-CncOutputDirectory {
                        param($From, $To)
                        if ($From.EndsWith('.stage')) { throw 'Injected publication failure.' }
                        if ($Failure -eq 'restore' -and $From.EndsWith('.backup')) { throw 'Injected restore failure.' }
                        [IO.Directory]::Move($From, $To)
                    }
                }
            }
            Invoke-CncBatch -SourceFolder $InputPath -OutputFolder $OutputPath -ReplaceExistingOutput 6>$null
        } $singleSource $protectedOutput $failure
    } catch { $caught = $_.Exception.Message }
    if ($failure -eq 'restore') {
        $backups = @(Get-ChildItem -LiteralPath $work -Directory -Force -Filter '*.backup')
        if ($caught -notlike '*Injected restore failure*' -or $backups.Count -ne 1 -or
            -not $caught.Contains($backups[0].FullName) -or
            (Test-Path -LiteralPath $protectedOutput) -or
            (Get-PreservationSnapshot $backups[0].FullName) -cne $expected) {
            throw "Failed rollback did not preserve and report the previous output: $caught"
        }
        $caught = $null
        try { Invoke-CncBatch -SourceFolder $singleSource -OutputFolder $protectedOutput -ReplaceExistingOutput 6>$null }
        catch { $caught = $_.Exception.Message }
        if ($caught -notlike 'Recover or move*') { throw "Retry did not protect an unrecovered backup: $caught" }
    } else {
        $expectedError = switch ($failure) {
            'write' { '*Injected staging write failure*' }
            'verify' { '*Injected staging verification failure*' }
            'publish' { '*Previous output was restored*' }
        }
        if ($caught -notlike $expectedError -or (Get-PreservationSnapshot $protectedOutput) -cne $expected) {
            throw "Output was not preserved after injected '$failure' failure: $caught"
        }
    }
}
if (Get-ChildItem -LiteralPath $work -Force | Where-Object { $_.Name -match '\.(stage|lock)$' }) {
    throw 'A temporary stage or lock remained after a handled failure.'
}
Write-Host 'PASS Unmanaged output requires opt-in; staging failures preserve it; publication failure rolls back; failed restore retains a recoverable backup.'

foreach ($badName in @('Layered-Missing-Panel.dxf','Layered-Offcenter.dxf','Layered-MultiPanel.dxf')) {
    $inputDir = Join-Path $work $badName.Replace('.dxf','')
    [void](New-Item -ItemType Directory -Path $inputDir -Force)
    Copy-Item (Join-Path $PSScriptRoot "TestFixtures/$badName") $inputDir
    $badOutput = Join-Path $work ("negative-" + $badName.Replace('.dxf',''))
    [void](New-Item -ItemType Directory -Path $badOutput -Force)
    Set-Content (Join-Path $badOutput 'sentinel.txt') 'must survive failed validation'
    $caught = $null
    try { Invoke-CncBatch -SourceFolder $inputDir -OutputFolder $badOutput 6>$null }
    catch { $caught = $_.Exception.Message }
    if (!$caught -or !(Test-Path (Join-Path $badOutput 'sentinel.txt'))) {
        throw "Invalid batch '$badName' was not rejected safely."
    }
}
Write-Host 'PASS Invalid batches are rejected and existing outputs are preserved.'
Write-Host "Review output retained at $work"
