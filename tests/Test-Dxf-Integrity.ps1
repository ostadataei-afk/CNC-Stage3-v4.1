$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path $PSScriptRoot '../Cnc.psm1') -Force -DisableNameChecking -PassThru
$fixture = Get-Item (Join-Path $PSScriptRoot 'TestFixtures/Legacy-One-Part.dxf')

function Assert-DxfRejected {
    param([string]$Reason, [scriptblock]$Action)
    try { & $Action 6>$null | Out-Null }
    catch {
        if ($_.Exception.Message -like "*$Reason*") { return }
        throw
    }
    throw "Expected DXF rejection containing '$Reason'."
}

foreach ($code in @(38,42,230)) {
    $document = Read-DxfDocument $fixture
    $outline = $document.Entities | Where-Object Type -eq 'LWPOLYLINE' | Select-Object -First 1
    $pair = $outline.Pairs | Where-Object Code -eq $code | Select-Object -First 1
    if ($null -eq $pair) { Add-DxfPair $outline.Pairs $code '-1' }
    else { $pair.Value = '-1' }
    Assert-DxfRejected "DXF group $code" { New-CncBatchPlan -Documents @($document) }
}

$document = Read-DxfDocument $fixture
$texts = Get-TextRecords $document
$feature = $texts | Where-Object IsFeature | Select-Object -First 1
Add-DxfPair $feature.Entity.Pairs 230 '-1'
Assert-DxfRejected 'DXF group 230' { New-CncBatchPlan -Documents @($document) }

$sourcePath = [System.IO.Path]::GetTempFileName()
$outputPath = [System.IO.Path]::GetTempFileName()
try {
    $lines = [System.IO.File]::ReadAllLines($fixture.FullName)
    $versionIndex = [array]::IndexOf($lines, '$ACADVER') + 2
    $unitsIndex = [array]::IndexOf($lines, '$INSUNITS') + 2
    $lines[$unitsIndex] = '1'
    [System.IO.File]::WriteAllLines($sourcePath, $lines)
    Assert-DxfRejected 'coordinates must be in millimetres' { Read-DxfDocument (Get-Item -LiteralPath $sourcePath) }
    $lines[$unitsIndex] = '4'

    # This annotation contains a non-ASCII character representable in both tested encodings.
    $annotationIndex = [array]::IndexOf($lines, '3650x2090:1x')
    $annotation = '3650x2090:1x Caf' + [char]0xE9
    $lines[$annotationIndex] = $annotation
    $entitySection = [array]::IndexOf($lines, 'ENTITIES')
    $lines = @($lines[0..$entitySection]) + @('999', 'comment before first entity') + @($lines[($entitySection + 1)..($lines.Length - 1)])

    [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
    $cases = @(
        @{ Version = 'AC1015'; Encoding = [System.Text.Encoding]::GetEncoding(1250) },
        @{ Version = 'AC1021'; Encoding = [System.Text.UTF8Encoding]::new($false) }
    )
    foreach ($case in $cases) {
        $lines[$versionIndex] = $case.Version
        [System.IO.File]::WriteAllLines($sourcePath, [string[]]$lines, $case.Encoding)
        $doc = Read-DxfDocument (Get-Item -LiteralPath $sourcePath)
        $plan = New-CncBatchPlan -Documents @($doc) 6>$null
        $generated = (ConvertTo-CncOutput -Documents $plan)[0]
        & $module { param($item, $path) Write-CncDxfOutput -Item $item -Path $path } $generated $outputPath
        $output = Get-Item -LiteralPath $outputPath
        $serialized = [System.IO.File]::ReadAllLines($outputPath, $case.Encoding)
        if ($annotation -cnotin $serialized -or 'comment before first entity' -cnotin $serialized) {
            throw "DXF version '$($case.Version)' lost an original annotation or comment."
        }
        if (-not (Test-GeneratedDxf -File $output -Plan $generated)) { throw 'Round-trip verification failed.' }
    }

    $changed = [string[]]$generated.Lines.Clone()
    $changed[[array]::IndexOf($changed, $annotation)] = 'deliberately changed annotation'
    [System.IO.File]::WriteAllLines($outputPath, $changed, $generated.Document.Encoding)
    Assert-DxfRejected 'serialized group changed' { Test-GeneratedDxf -File $output -Plan $generated }

    $changed = [string[]]$generated.Lines.Clone()
    $grooveHandle = Get-FirstValue $generated.SlotEntities[0] 5
    for ($i = 0; $i -lt $changed.Length; $i += 2) {
        if ($changed[$i].Trim() -eq '5' -and $changed[$i + 1] -eq $grooveHandle) { break }
    }
    for (; $i -lt $changed.Length; $i += 2) {
        if ($changed[$i].Trim() -eq '10') { $changed[$i + 1] = 'NaN'; break }
    }
    [System.IO.File]::WriteAllLines($outputPath, $changed, $generated.Document.Encoding)
    Assert-DxfRejected 'Non-finite DXF number' { Test-GeneratedDxf -File $output -Plan $generated }
} finally {
    [System.IO.File]::Delete($sourcePath)
    [System.IO.File]::Delete($outputPath)
}
Write-Host 'PASS DXF units, planar outlines, legacy/modern encodings, and round-trip integrity.'
