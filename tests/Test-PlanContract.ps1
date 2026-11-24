$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Cnc.psm1') -Force -DisableNameChecking

function Read-Fixture([string]$Name) {
    Read-DxfDocument (Get-Item -LiteralPath (Join-Path $PSScriptRoot "TestFixtures/$Name"))
}

$documents = @(
    Read-Fixture 'Layered-Original.dxf'
    Read-Fixture 'Legacy-One-Part.dxf'
    Read-Fixture 'Layered-Pair.dxf'
)
$plans = New-CncBatchPlan -Documents $documents 6>$null
$contract = ConvertTo-CncPlanContract -Documents $plans
$json = $contract | ConvertTo-Json -Depth 20 -Compress
$decoded = $json | ConvertFrom-Json -AsHashtable
if ($decoded.schemaVersion -ne 1 -or $decoded.units -ne 'mm' -or
    $decoded.files -isnot [array] -or $decoded.files.Count -ne 3) {
    throw 'Unexpected JSON contract header or file list.'
}
foreach ($index in 0..2) {
    $operations = $decoded.files[$index].operations
    if ($operations -isnot [array] -or $operations.Count -ne $index) {
        throw "Expected an array with $index operations for '$($decoded.files[$index].name)'."
    }
}
if (-not $decoded.files[1].operations[0].Contains('notch') -or
    $null -ne $decoded.files[1].operations[0].notch -or
    $null -eq $decoded.files[1].operations[0].groove) {
    throw 'A stand-alone groove must export the absent notch as null.'
}
$plans[1].FeatureRecords[0].GrooveOffset = -1
if (($contract | ConvertTo-Json -Depth 20 -Compress) -cne $json) {
    throw 'The exported contract changed when a plan was modified.'
}

$selections = foreach ($reverse in $false, $true) {
    $alpha = Read-Fixture 'Mix-R-Legacy.dxf'
    $beta = Read-Fixture 'Mix-L-Layered.dxf'
    $alpha.File = [IO.FileInfo]::new((Join-Path $PSScriptRoot 'Alpha.dxf'))
    $beta.File = [IO.FileInfo]::new((Join-Path $PSScriptRoot 'Beta.dxf'))
    $order = if ($reverse) { @($beta, $alpha) } else { @($alpha, $beta) }
    $paired = New-CncBatchPlan -Documents $order 6>$null
    if ($paired[0].File.Name -cne $order[0].File.Name -or
        $alpha.FeatureRecords[0].Role -ne 'R' -or $beta.FeatureRecords[0].Role -ne 'L') {
        throw 'Fallback pairing must assign roles by filename and retain caller order in the plan.'
    }
    $paired | Sort-Object { $_.File.Name } | ForEach-Object {
        $_.FeatureRecords[0] | Select-Object Role, State, GrooveEdge, Corner
    } | ConvertTo-Json -Compress
}
if ($selections[0] -cne $selections[1]) { throw 'Reversing the input changed CNC operations.' }

$duplicate = @(Read-Fixture 'Mix-R-Legacy.dxf'; Read-Fixture 'Mix-R-Legacy.dxf')
$duplicateError = try { New-CncBatchPlan -Documents $duplicate 6>$null | Out-Null } catch { $_.Exception.Message }
if ($duplicateError -notlike 'Duplicate input filename*') { throw 'Duplicate source names must be rejected.' }

function New-RepeatedPairDocument([string]$Name, [int]$Count) {
    $records = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $Count; $index++) {
        $records.Add([pscustomobject]@{
            Label = 'MULTI_SH_Z'
            HasSH = $true
            HasZ = $true
            Text = [pscustomobject]@{ EntityIndex = 10 + (2 * $index) }
            Shape = [pscustomobject]@{ Handle = "PART-$index"; Orientation = 'N' }
            Table = 2
            Role = $null
            State = $null
            GrooveEdge = $null
            HandleEdges = @()
            Corner = $null
            IsPair = $false
        })
    }
    return [pscustomobject]@{
        File = [IO.FileInfo]::new((Join-Path $PSScriptRoot $Name))
        Stats = [pscustomobject]@{ PairCount = 0 }
        FeatureRecords = $records.ToArray()
    }
}

$fourRepeated = New-RepeatedPairDocument 'Repeated-Four.dxf' 4
Resolve-GlobalPairs -Documents @($fourRepeated) 6>$null
$roles = @($fourRepeated.FeatureRecords | Sort-Object { $_.Text.EntityIndex } | ForEach-Object { $_.Role })
$corners = @($fourRepeated.FeatureRecords | Sort-Object { $_.Text.EntityIndex } | ForEach-Object { $_.Corner })
if ($fourRepeated.Stats.PairCount -ne 2 -or
    ($roles -join ',') -ne 'R,L,R,L' -or
    ($corners -join ',') -ne 'C,D,C,D') {
    throw 'Four identical SH+Z labels must form two successive mirrored R/L pairs.'
}

$sixRepeated = New-RepeatedPairDocument 'Repeated-Six.dxf' 6
Resolve-GlobalPairs -Documents @($sixRepeated) 6>$null
if ($sixRepeated.Stats.PairCount -ne 3) {
    throw 'Six identical SH+Z labels must form three pairs.'
}

$oddRepeated = New-RepeatedPairDocument 'Repeated-Odd.dxf' 3
$oddPairError = try { Resolve-GlobalPairs -Documents @($oddRepeated) 6>$null; $null } catch { $_.Exception.Message }
if ($oddPairError -notlike "*even number of times*found 3*") {
    throw "An odd number of repeated SH+Z labels must be rejected clearly: $oddPairError"
}

$cliOutput = & (Join-Path $root 'Export-Plan.ps1') -SourceFolder (Join-Path $PSScriptRoot 'Sample_A_Valid') 6>&1
$cliContract = ($cliOutput -join "`n") | ConvertFrom-Json -AsHashtable
if ($cliContract.files.Count -ne 10 -or $cliContract.schemaVersion -ne 1) {
    throw 'Export-Plan did not emit the expected standalone JSON.'
}
Write-Host 'PASS JSON contract, repeated-pair counts, deterministic pairing and duplicate input rejection.'
