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
    # A free-form name may precede the first _/- separator. The command zone
    # then contains one or two SH/Z commands, separated by _, -, or whitespace.
    # Spaces around separators and between a command and its numeric argument
    # are ignored. Parse the complete command zone to reject malformed tokens.
    $name = $Label.Trim()
    $number = '[0-9]+(?:[.,][0-9]+)?'
    $shPattern = '^(?:(?<prefix>' + $number + '))?SH(?:(?<offset>' + $number + '))?$'
    $zPattern = '^(?:(?<long>' + $number + '))?Z(?:(?<short>' + $number + '))?$'
    $commandPattern = '^(?:(?:' + $number + ')?SH(?:' + $number + ')?|(?:' + $number + ')?Z(?:' + $number + ')?)$'
    $firstSeparator = [regex]::Match($name, '[_-]')
    if ($firstSeparator.Success) {
        $leading = $name.Substring(0, $firstSeparator.Index).Trim()
        $remainder = $name.Substring($firstSeparator.Index)
        $normalizedLeading = [regex]::Replace($leading, '(?i)(SH|Z)[ \t]+(?=[0-9.,])', '$1')
        $leadingLooksLikeCommand = $normalizedLeading -match '^(?:[0-9.,]*)SH(?:$|[0-9.,])' -or
            $normalizedLeading -match '^(?:[0-9.,]*)Z(?:$|[0-9.,])'
        if ($leading -and $normalizedLeading -notmatch $commandPattern -and -not $leadingLooksLikeCommand) {
            $identifier = $leading
            $commands = $remainder.Substring(1)
        } else {
            $identifier = $null
            $commands = if (-not $leading) { $name.Substring(1) } else { $name }
        }
    } else {
        $identifier = $null
        $commands = $name
    }
    # A leading separator represents an intentionally empty name. Normalize
    # whitespace around punctuation separators, then preserve empty fields so
    # repeated/trailing punctuation remains an error.
    $commands = [regex]::Replace($commands, '[ \t]*([_-])[ \t]*', '$1')
    $commands = [regex]::Replace($commands, '(?i)(^|[_-])([0-9]+(?:[.,][0-9]+)?)[ \t]+(SH)(?=[ \t]*(?:$|[0-9.,]))', '$1$2$3')
    $commands = [regex]::Replace($commands, '(?i)(SH|Z)[ \t]+(?=[0-9.,])', '$1')
    $tokens = @($commands -split '[_-]' | ForEach-Object { $_.Trim() } | ForEach-Object { if ($_ -match '\s') { $_ -split '\s+' } else { $_ } })
    $hasSH = $false; $hasZ = $false
    $prefix = $null; $offset = 18.0; $long = 66.0; $short = 32.0

    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $token = [string]$tokens[$i]
        if ([string]::IsNullOrWhiteSpace($token)) {
            throw "Invalid feature label '$Label': an empty token or repeated separator is not allowed."
        }
        $sh = [regex]::Match($token, $shPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $z = [regex]::Match($token, $zPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($sh.Success) {
            if ($hasSH) { throw "Invalid feature label '$Label': SH appears more than once." }
            $hasSH = $true
            if ($sh.Groups['prefix'].Success) { $prefix = [double]::Parse($sh.Groups['prefix'].Value.Replace(',','.'), [System.Globalization.CultureInfo]::InvariantCulture) }
            if ($sh.Groups['offset'].Success) { $offset = [double]::Parse($sh.Groups['offset'].Value.Replace(',','.'), [System.Globalization.CultureInfo]::InvariantCulture) }
        } elseif ($z.Success) {
            if ($hasZ) { throw "Invalid feature label '$Label': Z appears more than once." }
            $hasZ = $true
            if ($z.Groups['long'].Success) { $long = [double]::Parse($z.Groups['long'].Value.Replace(',','.'), [System.Globalization.CultureInfo]::InvariantCulture) }
            if ($z.Groups['short'].Success) { $short = [double]::Parse($z.Groups['short'].Value.Replace(',','.'), [System.Globalization.CultureInfo]::InvariantCulture) }
        } else {
            throw "Invalid feature label '$Label': unsupported or malformed token '$token'."
        }
    }
    if (-not ($hasSH -or $hasZ)) { throw "Invalid feature label '$Label': neither SH nor Z was found." }
    if ($null -ne $prefix -and ($prefix -le 0 -or [double]::IsNaN($prefix) -or [double]::IsInfinity($prefix))) {
        throw "Invalid feature label '$Label': SH dimensional prefix must be positive and finite."
    }
    if ($hasSH -and ($offset -le 0 -or [double]::IsNaN($offset) -or [double]::IsInfinity($offset))) {
        throw "Invalid feature label '$Label': SH offset must be positive and finite."
    }
    if ($hasZ -and ($long -le 0 -or $short -le 0 -or [double]::IsNaN($long) -or [double]::IsInfinity($long) -or [double]::IsNaN($short) -or [double]::IsInfinity($short))) {
        throw "Invalid feature label '$Label': both Z lengths must be positive and finite."
    }
    return [pscustomobject]@{
        HasSH = $hasSH; HasZ = $hasZ; Identifier = $identifier
        Prefix = $prefix; GrooveOffset = $offset
        LongLength = $long; ShortLength = $short
    }
}

function Test-FeatureLabelCandidate {
    param([string]$Label)
    # Name text is free-form; only a command-shaped token in the command zone
    # makes the label a candidate. This keeps ordinary WASH/SHABC annotations
    # ignored while allowing names such as SHABRANG_SH.
    $value = [regex]::Replace($Label.Trim(), '(?i)(SH|Z)[ \t]+(?=[0-9.,])', '$1')
    $value = [regex]::Replace($value, '(?i)(^|[_-])([0-9]+(?:[.,][0-9]+)?)[ \t]+(SH)(?=[ \t]*(?:$|[0-9.,]))', '$1$2$3')
    $firstSeparator = [regex]::Match($value, '[_-]')
    $commandZone = if ($firstSeparator.Success) { $value.Substring($firstSeparator.Index + 1) } else { $value }
    $tokens = @($commandZone -split '[_\-\s]+' | ForEach-Object { $_.Trim() })
    foreach ($token in $tokens) {
        if ($token -match '^(?:[0-9.,]*)SH(?:$|[0-9.,])' -or
            $token -match '^(?:[0-9.,]*)Z(?:$|[0-9.,])') {
            return $true
        }
    }
    return $false
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
