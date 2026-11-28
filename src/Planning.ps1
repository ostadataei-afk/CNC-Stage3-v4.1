function Get-FilenamePairRole {
    param([string]$FileName)
    # Only standalone tokens count: R, L, Right, Left (case-insensitive).
    # Hyphens, underscores, spaces and parentheses are supported separators.
    # Words containing these letters (e.g. Drawer, Rail) must not set a role.
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $r = [regex]::IsMatch($stem, '(?i)(?:^|[^a-z0-9])(?:R|RIGHT)(?=$|[^a-z0-9])')
    $l = [regex]::IsMatch($stem, '(?i)(?:^|[^a-z0-9])(?:L|LEFT)(?=$|[^a-z0-9])')
    if ($r -and $l) { throw "File '$FileName' contains both R and L role markers; rename it unambiguously." }
    if ($r) { return 'R' }
    if ($l) { return 'L' }
    return $null
}

function Resolve-GlobalPairs {
    param([object[]]$Documents)
    # Output files are named after the input, so the batch must have unique filenames.
    $fileNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($document in $Documents) {
        if (-not $fileNames.Add($document.File.Name)) {
            throw "Duplicate input filename '$($document.File.Name)'; each DXF in a batch must have a unique filename."
        }
        $document.Stats.PairCount = 0
    }

    # Keep each label's pairing stable across input enumeration order:
    # file names sort invariantly, and TEXT order is preserved within each file.
    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($document in $Documents) {
        foreach ($record in $document.FeatureRecords) {
            if (-not ($record.HasSH -and $record.HasZ)) {
                continue
            }
            $candidates.Add([pscustomobject]@{
                Label = $record.Label
                Document = $document
                Record = $record
                EntityIndex = [int]$record.Text.EntityIndex
            })
        }
    }
    $pairGroups = @($candidates | Group-Object -Property Label)
    foreach ($group in $pairGroups) {
        if ($group.Count -lt 2 -or ($group.Count % 2) -ne 0) {
            $sources = (@($group.Group | ForEach-Object { $_.Document.File.Name } | Sort-Object -Unique) -join ', ')
            throw (
                "Label '$($group.Name)' contains SH and Z and must occur an even number of times " +
                "(at least twice) across folder A; found $($group.Count) in file(s): $sources."
            )
        }
        # Sort deterministically by filename, then by original TEXT entity order.
        # Consecutive entries become R/L pairs.
        $orderedMembers = @(
            $group.Group |
                Sort-Object @{ Expression = { $_.Document.File.Name.ToUpperInvariant() } }, @{ Expression = { $_.EntityIndex } }
        )
        for ($pairOffset = 0; $pairOffset -lt $orderedMembers.Count; $pairOffset += 2) {
            $members = @($orderedMembers[$pairOffset], $orderedMembers[$pairOffset + 1])
            # Within one DXF, lower TEXT entity index is R and the next is L.
            # For different files, explicit filename roles take precedence over name order.
            if (-not [object]::ReferenceEquals($members[0].Document, $members[1].Document)) {
                $role0 = Get-FilenamePairRole -FileName $members[0].Document.File.Name
                $role1 = Get-FilenamePairRole -FileName $members[1].Document.File.Name
                if ($null -ne $role0 -and $null -ne $role1 -and $role0 -eq $role1) {
                    throw (
                        "Pair '$($group.Name)': both files claim role '$role0' " +
                        "('$($members[0].Document.File.Name)' and '$($members[1].Document.File.Name)')."
                    )
                }
                # A single explicit marker determines the counterpart's opposite role.
                # With no markers, compare names independently of caller order and culture.
                $swap = ($role0 -eq 'L') -or ($role1 -eq 'R')
                if ($null -eq $role0 -and $null -eq $role1) {
                    $swap = [StringComparer]::OrdinalIgnoreCase.Compare($members[0].Document.File.Name, $members[1].Document.File.Name) -gt 0
                }
                if ($swap) { $members = @($members[1], $members[0]) }
            }
            $first = $members[0].Record
            $second = $members[1].Record
            if ([object]::ReferenceEquals($first.Shape, $second.Shape)) {
                throw "Pair label '$($group.Name)' resolves twice to the same part outline."
            }
            if ($first.Table -ne $second.Table) {
                throw (
                    "Pair '$($group.Name)' selects inconsistent tables in " +
                    "'$($members[0].Document.File.Name)' and '$($members[1].Document.File.Name)'."
                )
            }
            $state = Get-SymmetryState -FirstOrientation $first.Shape.Orientation -SecondOrientation $second.Shape.Orientation
            Write-Host "  Pair '$($group.Name)': R $($members[0].Document.File.Name) [TEXT $($members[0].EntityIndex)] -> L $($members[1].Document.File.Name) [TEXT $($members[1].EntityIndex)] | $state" -ForegroundColor DarkCyan
            foreach ($index in 0,1) {
                $role = if ($index -eq 0) { 'R' } else { 'L' }
                $record = $members[$index].Record
                $rule = Get-TableRule -Table $record.Table -State $state -Role $role
                $record.Role = $role
                $record.State = $state
                $record.GrooveEdge = $rule.Groove
                $record.HandleEdges = @($rule.Handles)
                $record.Corner = $rule.Corner
                $record.IsPair = $true
            }
            $members[0].Document.Stats.PairCount++
            if (-not [object]::ReferenceEquals($members[0].Document, $members[1].Document)) {
                $members[1].Document.Stats.PairCount++
            }
        }
    }
}
