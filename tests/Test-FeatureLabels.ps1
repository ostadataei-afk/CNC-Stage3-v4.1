# Label parsing, classification, and notch size rules.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../Cnc.psm1') -Force -DisableNameChecking
$cases = @(
    @{ L='SH'; O=$true; S=$true; Z=$false; Offset=18; Long=66; Short=32 }
    @{ L='KNR_ sh'; O=$true; S=$true; Z=$false; Offset=18; Long=66; Short=32 }
    @{ L=' KNR _ sh '; O=$true; S=$true; Z=$false; Offset=18; Long=66; Short=32 }
    @{ L='02 KAF_SH'; O=$true; S=$true; Z=$false; Offset=18; Long=66; Short=32 }
    @{ L='01 BKSHO_SH'; O=$true; S=$true; Z=$false; Offset=18; Long=66; Short=32 }
    @{ L='02 KAF _ SH _ Z'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='02 KAF - 300SH25 - 80Z40'; O=$true; S=$true; Z=$true; Offset=25; Long=80; Short=40; Prefix=300 }
    @{ L='KNR - z40'; O=$true; S=$false; Z=$true; Offset=18; Long=66; Short=40 }
    @{ L=' KNR _ sh _ z40 '; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=40 }
    @{ L='Z'; O=$true; S=$false; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='sh'; O=$true; S=$true; Z=$false; Offset=18; Long=66; Short=32 }
    @{ L='z'; O=$true; S=$false; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='SH_Z'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='Z_SH'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='sh_Z'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='Z_sH'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='SH-Z'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='Z-SH'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='_Z-SH'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='-SH_Z'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='SH 25-Z'; O=$true; S=$true; Z=$true; Offset=25; Long=66; Short=32 }
    @{ L='300 SH25'; O=$true; S=$true; Z=$false; Offset=25; Long=66; Short=32; Prefix=300 }
    @{ L='300 SH 25'; O=$true; S=$true; Z=$false; Offset=25; Long=66; Short=32; Prefix=300 }
    @{ L='300 SH 25-Z'; O=$true; S=$true; Z=$true; Offset=25; Long=66; Short=32; Prefix=300; Identifier=$null }
    @{ L='Name_300 SH 25-Z'; O=$true; S=$true; Z=$true; Offset=25; Long=66; Short=32; Prefix=300; Identifier='Name' }
    @{ L='300 SH Z'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=32; Prefix=300 }
    @{ L='SH 80Z40'; O=$true; S=$true; Z=$true; Offset=18; Long=80; Short=40 }
    @{ L='Name_Z 300SH25'; O=$true; S=$true; Z=$true; Offset=25; Long=66; Short=32; Prefix=300 }
    @{ L='80 Z 40'; O=$true; S=$false; Z=$true; Offset=18; Long=80; Short=40 }
    @{ L='Name_Z_300SH25'; O=$true; S=$true; Z=$true; Offset=25; Long=66; Short=32; Prefix=300 }
    @{ L='Name_Z300_SH25'; O=$true; S=$true; Z=$true; Offset=25; Long=66; Short=300 }
    @{ L='Name_Z 300 SH 25'; O=$false; Error='ambiguous spacing'; Alternatives=@('Name_Z_300SH25','Name_Z300_SH25') }
    @{ L='SH 80 Z40'; O=$false; Error='ambiguous spacing' }
    @{ L='Zir _ SH 100 _ Z'; O=$true; S=$true; Z=$true; Offset=100; Long=66; Short=32 }
    @{ L='Zir_shab_Z'; O=$false }
    @{ L='01_SH100'; O=$true; S=$true; Z=$false; Offset=100; Long=66; Short=32 }
    @{ L='02_300SH100_Z'; O=$true; S=$true; Z=$true; Offset=100; Long=66; Short=32; Prefix=300 }
    @{ L='SH25_Z'; O=$true; S=$true; Z=$true; Offset=25; Long=66; Short=32 }
    @{ L='SH25.5_Z'; O=$true; S=$true; Z=$true; Offset=25.5; Long=66; Short=32 }
    @{ L='SH25,5_Z'; O=$true; S=$true; Z=$true; Offset=25.5; Long=66; Short=32 }
    @{ L='300SH25.5_80.25Z40.75'; O=$true; S=$true; Z=$true; Offset=25.5; Long=80.25; Short=40.75; Prefix=300 }
    @{ L='80Z40_300SH25'; O=$true; S=$true; Z=$true; Offset=25; Long=80; Short=40; Prefix=300 }
    @{ L='Z40_SH25'; O=$true; S=$true; Z=$true; Offset=25; Long=66; Short=40 }
    @{ L='SH_80Z'; O=$true; S=$true; Z=$true; Offset=18; Long=80; Short=32 }
    @{ L='SH_Z40'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=40 }
    @{ L='SH_80Z40'; O=$true; S=$true; Z=$true; Offset=18; Long=80; Short=40 }
    @{ L='300SH25-80Z40'; O=$true; S=$true; Z=$true; Offset=25; Long=80; Short=40; Prefix=300 }
    @{ L='02_z40_sH25.25'; O=$true; S=$true; Z=$true; Offset=25.25; Long=66; Short=40 }
    @{ L='SH_0.5Z0.25'; O=$true; S=$true; Z=$true; Offset=18; Long=0.5; Short=0.25 }
    @{ L='300.5SH_Z'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=32; Prefix=300.5 }
    @{ L='300SH'; O=$true; S=$true; Z=$false; Offset=18; Long=66; Short=32; Prefix=300 }
    @{ L='SH25._Z'; O=$false }
    @{ L='SH 25_Z'; O=$true; S=$true; Z=$true; Offset=25; Long=66; Short=32 }
    @{ L='SH.5_Z'; O=$false }
    @{ L='SH-25_Z'; O=$false }
    @{ L='SH25.5.5_Z'; O=$false }
    @{ L='SH_Z0'; O=$false }
    @{ L='SH_0Z40'; O=$false }
    @{ L='Z0_SH'; O=$false }
    @{ L='SH0_Z'; O=$false }
    @{ L='0SH_Z'; O=$false }
    @{ L='SH_SH_Z'; O=$false }
    @{ L='Z_Z_SH'; O=$false }
    @{ L='Z_SH_300SH'; O=$false }
    @{ L='SH_Z_EXTRA'; O=$false }
    @{ L='SH__Z'; O=$false }
    @{ L='SHZ'; O=$false }
    @{ L='SHABC_Z'; O=$true; S=$false; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='WASH_Z'; O=$true; S=$false; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='SHABRANG_SH'; O=$true; S=$true; Z=$false; Offset=18; Long=66; Short=32 }
    @{ L='SH_Z-'; O=$false }
    @{ L='SH_-Z'; O=$false }
    @{ L='SH_80Z0'; O=$false }
    @{ L='SH_80Z40_SH'; O=$false }
)
$passed = 0; $failed = 0
foreach ($c in $cases) {
    $errorText = $null; $got = $null
    try { $got = Parse-FeatureLabel -Label $c.L } catch { $errorText = $_.Exception.Message }
    $ok = ($c.O -eq ($null -ne $got))
    if ($c.ContainsKey('Error')) { $ok = $ok -and $errorText -like "*$($c.Error)*" }
    foreach ($example in $c.Alternatives) { $ok = $ok -and $errorText.Contains($example) }
    if ($ok -and $null -ne $got) {
        $ok = $got.HasSH -eq $c.S -and $got.HasZ -eq $c.Z
        $ok = $ok -and [math]::Abs($got.GrooveOffset - $c.Offset) -lt 0.00001
        $ok = $ok -and [math]::Abs($got.LongLength - $c.Long) -lt 0.00001
        $ok = $ok -and [math]::Abs($got.ShortLength - $c.Short) -lt 0.00001
        if ($c.ContainsKey('Prefix')) { $ok = $ok -and [math]::Abs($got.Prefix - $c.Prefix) -lt 0.00001 }
        else { $ok = $ok -and $null -eq $got.Prefix }
        if ($c.ContainsKey('Identifier')) { $ok = $ok -and $got.Identifier -ceq $c.Identifier }
    }
    if ($ok) { $passed++ } else { $failed++; Write-Host "FAILED: $($c.L), expected valid=$($c.O), observed=$($null -ne $got), error=$errorText" -ForegroundColor Red }
}
$textCases = @(
    @{ Label='WASH'; IsFeature=$false }
    @{ Label='SHABC'; IsFeature=$false }
    @{ Label='SHABC_Z'; IsFeature=$true; HasSH=$false; HasZ=$true }
    @{ Label='300 SH 25-Z'; IsFeature=$true; HasSH=$true; HasZ=$true }
    @{ Label='SH25-foo'; Error='Invalid feature label' }
    @{ Label='SH-'; Error='Invalid feature label' }
    @{ Label='SH-25'; Error='Invalid feature label' }
    @{ Label='SH+25'; Error='Invalid feature label' }
    @{ Label='SH+25-Z40'; Error='Invalid feature label' }
    @{ Label='Name_SH+25'; Error='Invalid feature label' }
    @{ Label='Name_SHZ'; Error='Invalid feature label' }
    @{ Label='SH Z - TMP'; Error='Invalid feature label' }
    @{ Label='Name_Z 300 SH 25'; Error='ambiguous spacing' }
)
foreach ($case in $textCases) {
    $entity = [pscustomobject]@{
        Type = 'TEXT'
        SourceIndex = 0
        Pairs = @((New-DxfPair 1 $case.Label), (New-DxfPair 10 '20'), (New-DxfPair 20 '30'))
    }
    $errorText = $null
    $records = @()
    try { $records = Get-TextRecords -Document ([pscustomobject]@{ Entities = @($entity) }) }
    catch { $errorText = $_.Exception.Message }
    $ok = if ($case.ContainsKey('Error')) {
        $errorText -like "*$($case.Error)*"
    } else {
        $null -eq $errorText -and $records.Count -eq 1 -and $records[0].IsFeature -eq $case.IsFeature -and
            (-not $case.IsFeature -or ($records[0].HasSH -eq $case.HasSH -and $records[0].HasZ -eq $case.HasZ))
    }
    if ($ok) { $passed++ }
    else { $failed++; Write-Host "FAILED TEXT classification: $($case.Label), error=$errorText" -ForegroundColor Red }
}
$shape = [pscustomobject]@{ Width = 300.0; Height = 800.0 }
$zChecks = @(
    @{ Label='SH_799.99Z299.99'; Table=2; Long=799.99; Short=299.99; Accept=$true }
    @{ Label='SH_800Z40'; Table=2; Long=800; Short=40; Accept=$false }
    @{ Label='SH_799Z300'; Table=2; Long=799; Short=300; Accept=$false }
    @{ Label='300SH_299.99Z799.99'; Table=1; Long=299.99; Short=799.99; Accept=$true }
    @{ Label='300SH_300Z50'; Table=1; Long=300; Short=50; Accept=$false }
    @{ Label='300SH_200Z800'; Table=1; Long=200; Short=800; Accept=$false }
    @{ Label='SH_9999Z40'; Table=2; Long=9999; Short=40; Accept=$false }
)
foreach ($zcheck in $zChecks) {
    $accepted = $true
    $params = [pscustomobject]@{ LongLength = $zcheck.Long; ShortLength = $zcheck.Short }
    try { Assert-ZNotchFitsPart -Shape $shape -Label $zcheck.Label -ZParameters $params -Table $zcheck.Table }
    catch { $accepted = $false }
    if ($accepted -eq $zcheck.Accept) { $passed++ }
    else { $failed++; Write-Host "FAILED Z fit: $($zcheck.Label)" -ForegroundColor Red }
}
Write-Host "Feature label tests: $passed passed, $failed failed." -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
if ($failed -gt 0) { throw 'Some label safety tests failed.' }
