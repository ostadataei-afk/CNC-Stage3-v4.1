$ErrorActionPreference = 'Stop'

$suites = @(
    'Test-FeatureLabels.ps1'
    'Test-Geometry.ps1'
    'Test-Dxf-Integrity.ps1'
    'Test-OptiCut.ps1'
    'Test-PlanContract.ps1'
    'Test-Preservation.ps1'
)

foreach ($suite in $suites) {
    Write-Host "`n=== $suite ===" -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot $suite)
}

Write-Host "`nAll $($suites.Count) test suites passed." -ForegroundColor Green
