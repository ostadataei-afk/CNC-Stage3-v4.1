function Get-DimensionText {
    param([string]$Value)
    if ($Value -match '^\s*(?<w>\d+(?:[.,]\d+)?)\s*[xX×]\s*(?<h>\d+(?:[.,]\d+)?)(?:\s*:.*)?\s*$') {
        $w = [double]::Parse($Matches['w'].Replace(',', '.'), [System.Globalization.CultureInfo]::InvariantCulture)
        $h = [double]::Parse($Matches['h'].Replace(',', '.'), [System.Globalization.CultureInfo]::InvariantCulture)
        return [pscustomobject]@{ Width = $w; Height = $h }
    }
    return $null
}

function Parse-FeatureLabel {
    param([string]$Label)
    $parsed = Read-FeatureLabel -Label $Label
    if ($null -eq $parsed) { throw "Invalid feature label '$Label': neither SH nor Z was found." }
    return $parsed
}

function Read-FeatureLabel {
    param([string]$Label)
    # A label can have a name before the first punctuation separator. If the
    # first field begins like a command, preserve it even when it is malformed.
    $segments = @($Label.Trim() -split '[_-]' | ForEach-Object { $_.Trim() })
    $marker = '(?:[+0-9.,]+\s*)?(?:SH|Z)(?=$|[\s+0-9.,]|(?:SH|Z)(?:$|[\s+0-9.,]))'
    $identifier = $null
    if ($segments.Count -gt 1 -and $segments[0] -notmatch ('^' + $marker)) {
        if ($segments[0]) { $identifier = $segments[0] }
        $segments = $segments[1..($segments.Count - 1)]
    }
    if (($segments -join ' ') -notmatch ('(?:^|\s)' + $marker)) { return $null }

    if ($segments -contains '') {
        throw "Invalid feature label '$Label': an empty token or repeated separator is not allowed."
    }
    # Punctuation always separates commands. Spaces can separate commands
    # or bind an adjacent number, so check each possible boundary.
    $commandSets = [System.Collections.Generic.List[string[]]]::new()
    if ($segments.Count -le 2) { $commandSets.Add($segments) }
    if ($segments.Count -eq 1) {
        $segment = $segments[0]
        foreach ($boundary in [regex]::Matches($segment, '\s+')) {
            $commandSets.Add(@($segment.Substring(0, $boundary.Index), $segment.Substring($boundary.Index + $boundary.Length)))
        }
    }
    $number = '[0-9]+(?:[.,][0-9]+)?'
    $command = [regex]('(?i)^(?:(?<before>' + $number + ')\s*)?(?<operation>SH|Z)(?:\s*(?<after>' + $number + '))?$')
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $parsed = $null
    $firstSpelling = $null
    $hasInvalidNumber = $false
    foreach ($commands in $commandSets) {
        $commandMatches = @($commands | ForEach-Object { $command.Match($_) })
        if ($commandMatches.Success -contains $false) { continue }
        if ($commandMatches.Count -eq 2 -and $commandMatches[0].Groups['operation'].Value -ieq $commandMatches[1].Groups['operation'].Value) { continue }

        $result = [pscustomobject]@{
            HasSH = $false; HasZ = $false; Identifier = $identifier
            Prefix = $null; GrooveOffset = 18.0
            LongLength = 66.0; ShortLength = 32.0
        }
        $valid = $true
        foreach ($match in $commandMatches) {
            $before = if ($match.Groups['before'].Success) { [double]::Parse($match.Groups['before'].Value.Replace(',', '.'), $culture) }
            $after = if ($match.Groups['after'].Success) { [double]::Parse($match.Groups['after'].Value.Replace(',', '.'), $culture) }
            if (($null -ne $before -and ($before -le 0 -or -not [double]::IsFinite($before))) -or
                ($null -ne $after -and ($after -le 0 -or -not [double]::IsFinite($after)))) {
                $hasInvalidNumber = $true
                $valid = $false
                break
            }
            if ($match.Groups['operation'].Value -ieq 'SH') {
                $result.HasSH = $true
                $result.Prefix = $before
                if ($null -ne $after) { $result.GrooveOffset = $after }
            } else {
                $result.HasZ = $true
                if ($null -ne $before) { $result.LongLength = $before }
                if ($null -ne $after) { $result.ShortLength = $after }
            }
        }
        if (-not $valid) { continue }
        $spelling = ($commands -replace '\s+', '') -join '_'
        if ($identifier) { $spelling = "${identifier}_$spelling" }
        if ($null -ne $parsed) {
            throw "Invalid feature label '$Label': ambiguous spacing; write '$firstSpelling' or '$spelling' to specify the intended commands."
        }
        $firstSpelling = $spelling
        $parsed = $result
    }
    if ($null -ne $parsed) { return $parsed }
    if ($hasInvalidNumber) { throw "Invalid feature label '$Label': command parameters must be positive and finite." }
    throw "Invalid feature label '$Label': expected one SH or Z command, or one of each."
}

function Get-Orientation {
    param([object]$Shape)
    if ([math]::Abs($Shape.Width - $Shape.Height) -lt 0.001) { throw "Part handle '$($Shape.Handle)' is square; the agreed N/Y rotation rule does not define square parts." }
    if ($Shape.Width -gt $Shape.Height) { return 'N' }
    return 'Y'
}

function Get-SymmetryState {
    param([string]$FirstOrientation, [string]$SecondOrientation)
    if ($FirstOrientation -notin @('N','Y') -or $SecondOrientation -notin @('N','Y')) { throw "Invalid orientation state '$FirstOrientation/$SecondOrientation'." }
    if ($FirstOrientation -eq 'N' -and $SecondOrientation -eq 'N') { return 'NN' }
    if ($FirstOrientation -eq 'Y' -and $SecondOrientation -eq 'Y') { return 'Y/Y' }
    return "$FirstOrientation/$SecondOrientation"
}

function Get-TableNumber {
    param([object]$Prefix, [object]$Shape, [string]$Label)
    $sizeTolerance = 0.1 # millimetres; original v4.1 tolerance
    if ($null -eq $Prefix) { return 2 }
    $matchWidth = [math]::Abs([double]$Shape.Width - [double]$Prefix) -lt $sizeTolerance
    $matchHeight = [math]::Abs([double]$Shape.Height - [double]$Prefix) -lt $sizeTolerance
    if (-not $matchWidth -and -not $matchHeight) { throw "Label '$Label': number before SH ($Prefix) does not match either dimension of part $($Shape.Width) x $($Shape.Height) mm." }
    if ($matchWidth -and $matchHeight) { return 1 }
    $small = [math]::Min([double]$Shape.Width, [double]$Shape.Height)
    if ([math]::Abs([double]$Prefix - $small) -lt $sizeTolerance) { return 1 }
    return 2
}

function Assert-ZNotchFitsPart {
    param([object]$Shape, [string]$Label, [object]$ZParameters, [int]$Table)
    $small = [math]::Min([double]$Shape.Width, [double]$Shape.Height)
    $large = [math]::Max([double]$Shape.Width, [double]$Shape.Height)
    # Existing CNC convention: table 1 long notch on SHORT side;
    # table 2 long notch on LONG side.  No cutting rule is changed.
    $beforeZLimit = if ($Table -eq 1) { $small } else { $large }
    $afterZLimit  = if ($Table -eq 1) { $large } else { $small }
    if ([double]$ZParameters.LongLength -ge $beforeZLimit -or [double]$ZParameters.ShortLength -ge $afterZLimit) {
        throw "Label '$Label': Z lengths ($($ZParameters.LongLength), $($ZParameters.ShortLength)) do not fit the $($Shape.Width)x$($Shape.Height) mm part under table $Table (limits: < $beforeZLimit and < $afterZLimit mm)."
    }
}

function Get-TableRule {
    param([int]$Table, [string]$State, [string]$Role)
    $key = "$State|$Role"
    $table1 = @{
        'NN|R' = @{ Groove = 'BC'; Handles = @('DA','AB'); Corner = 'A' }
        'NN|L' = @{ Groove = 'BC'; Handles = @('CD','DA'); Corner = 'D' }
        'N/Y|R' = @{ Groove = 'BC'; Handles = @('DA','AB'); Corner = 'A' }
        'N/Y|L' = @{ Groove = 'CD'; Handles = @('DA','AB'); Corner = 'A' }
        'Y/N|R' = @{ Groove = 'CD'; Handles = @('DA','AB'); Corner = 'A' }
        'Y/N|L' = @{ Groove = 'BC'; Handles = @('DA','AB'); Corner = 'A' }
        'Y/Y|R' = @{ Groove = 'AB'; Handles = @('BC','CD'); Corner = 'C' }
        'Y/Y|L' = @{ Groove = 'AB'; Handles = @('CD','DA'); Corner = 'D' }
    }
    $table2 = @{
        'NN|R' = @{ Groove = 'AB'; Handles = @('BC','CD'); Corner = 'C' }
        'NN|L' = @{ Groove = 'AB'; Handles = @('CD','DA'); Corner = 'D' }
        'N/Y|R' = @{ Groove = 'AB'; Handles = @('BC','CD'); Corner = 'C' }
        'N/Y|L' = @{ Groove = 'BC'; Handles = @('DA','AB'); Corner = 'A' }
        'Y/N|R' = @{ Groove = 'BC'; Handles = @('DA','AB'); Corner = 'A' }
        'Y/N|L' = @{ Groove = 'AB'; Handles = @('BC','CD'); Corner = 'C' }
        'Y/Y|R' = @{ Groove = 'BC'; Handles = @('DA','AB'); Corner = 'A' }
        'Y/Y|L' = @{ Groove = 'DA'; Handles = @('AB','BC'); Corner = 'B' }
    }
    $rules = if ($Table -eq 1) { $table1 } else { $table2 }
    if (-not $rules.ContainsKey($key)) { throw "No symmetry rule exists for table $Table, state '$State', role '$Role'." }
    return $rules[$key]
}
