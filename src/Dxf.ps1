function New-DxfPair {
    param([int]$Code, [string]$Value)
    [pscustomobject]@{ Code = $Code; CodeText = ('{0,3}' -f $Code); Value = $Value }
}

function Add-DxfPair {
    param([System.Collections.Generic.List[object]]$List, [int]$Code, [string]$Value)
    $List.Add((New-DxfPair -Code $Code -Value $Value))
}

function Get-FirstValue {
    param([object]$Entity, [int]$Code)
    foreach ($pair in $Entity.Pairs) { if ($pair.Code -eq $Code) { return ([string]$pair.Value).Trim() } }
    return $null
}

function ConvertFrom-DxfNumber {
    param([string]$Value)
    $number = [double]::Parse($Value.Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture)
    if (-not [double]::IsFinite($number)) { throw "Non-finite DXF number '$Value' is not supported." }
    return $number
}

function ConvertTo-DxfNumber {
    param([double]$Value)
    if (-not [double]::IsFinite($Value)) { throw "Non-finite DXF number '$Value' is not supported." }
    return $Value.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-EntityVertices {
    param([object]$Entity)
    $points = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Entity.Pairs.Count; $i++) {
        if ($Entity.Pairs[$i].Code -eq 10) {
            if (($i + 1) -ge $Entity.Pairs.Count -or $Entity.Pairs[$i + 1].Code -ne 20) {
                throw "LWPOLYLINE handle '$((Get-FirstValue $Entity 5))' has an invalid vertex coordinate pair (codes 10/20)."
            }
            $points.Add([pscustomobject]@{ X = (ConvertFrom-DxfNumber $Entity.Pairs[$i].Value); Y = (ConvertFrom-DxfNumber $Entity.Pairs[$i + 1].Value) })
            $i++
        }
    }
    return ,$points.ToArray()
}

function Read-DxfHeader {
    param([System.IO.TextReader]$Reader)
    $header = @{}
    $inHeader = $false
    $sectionStart = $false
    $variable = $null
    while ($null -ne ($codeLine = $Reader.ReadLine())) {
        $value = $Reader.ReadLine()
        if ($null -eq $value) { break }
        $code = 0
        if (-not [int]::TryParse($codeLine.Trim(), [ref]$code)) { break }
        $value = $value.Trim()
        if (-not $inHeader) {
            if ($sectionStart -and $code -eq 2) {
                $inHeader = $value -eq 'HEADER'
            }
            $sectionStart = $code -eq 0 -and $value -eq 'SECTION'
        } elseif ($code -eq 0) {
            break
        } elseif ($code -eq 9) {
            $variable = $value
        } elseif ($variable -and $code -ne 999) {
            $header[$variable] = $value
            $variable = $null
        }
    }
    return $header
}

function Read-DxfDocument {
    param([System.IO.FileInfo]$File)
    $stream = [System.IO.File]::OpenRead($File.FullName)
    try {
        $hasUtf8Bom = $stream.ReadByte() -eq 0xEF -and $stream.ReadByte() -eq 0xBB -and $stream.ReadByte() -eq 0xBF
        $start = if ($hasUtf8Bom) { 3L } else { 0L }
        $stream.Position = $start
        # DXF header keys and supported codepage names are ASCII even if text data is not.
        $headerReader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::Latin1, $false, 1024, $true)
        try { $header = Read-DxfHeader $headerReader }
        finally { $headerReader.Dispose() }
        $unitsText = $header['$INSUNITS']
        $units = 0
        if ($null -ne $unitsText -and (-not [int]::TryParse($unitsText, [ref]$units) -or $units -notin @(0,4))) {
            throw "File '$($File.Name)' has unsupported DXF insertion units '$unitsText'; coordinates must be in millimetres."
        }
        $version = $header['$ACADVER']
        $codePage = $header['$DWGCODEPAGE']
        $modernVersion = $version -match '^AC([0-9]{4})$' -and [int]$Matches[1] -ge 1021
        if ($hasUtf8Bom -and $version -and -not $modernVersion) {
            throw "File '$($File.Name)' has a UTF-8 BOM with older DXF version '$version'."
        }
        $encoding = if ($hasUtf8Bom -or $modernVersion) {
            [System.Text.UTF8Encoding]::new($hasUtf8Bom, $true)
        } else {
            $codePageNumber = 20127 # ASCII when no legacy codepage is declared.
            if ($codePage -and $codePage -ne 'ANSI_20127') {
                if ($codePage -notmatch '^ANSI_(874|932|936|949|950|125[0-8])$') {
                    throw "File '$($File.Name)' has unsupported legacy DXF codepage '$codePage'."
                }
                $codePageNumber = [int]$Matches[1]
                [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
            }
            [System.Text.Encoding]::GetEncoding($codePageNumber, [System.Text.EncoderFallback]::ExceptionFallback, [System.Text.DecoderFallback]::ExceptionFallback)
        }
        $stream.Position = $start
        $reader = [System.IO.StreamReader]::new($stream, $encoding, $false, 1024, $true)
        try {
            $rawLines = [System.Collections.Generic.List[string]]::new()
            while ($null -ne ($line = $reader.ReadLine())) { $rawLines.Add($line) }
        } catch [System.Text.DecoderFallbackException] {
            throw "File '$($File.Name)' contains text that cannot be decoded as $($encoding.WebName)."
        } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
    if (($rawLines.Count % 2) -ne 0) { throw 'DXF has an odd number of group-code/value lines.' }
    $pairs = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $rawLines.Count; $i += 2) {
        $code = 0
        if (-not [int]::TryParse($rawLines[$i].Trim(), [ref]$code)) { throw "Invalid DXF group code at line $($i + 1)." }
        $pairs.Add([pscustomobject]@{ Code = $code; CodeText = $rawLines[$i]; Value = $rawLines[$i + 1] })
    }
    $entityBodyStart = -1; $entityBodyEnd = -1
    for ($i = 0; $i -lt ($pairs.Count - 1); $i++) {
        if ($pairs[$i].Code -eq 0 -and $pairs[$i].Value.Trim() -eq 'SECTION' -and $pairs[$i + 1].Code -eq 2 -and $pairs[$i + 1].Value.Trim() -eq 'ENTITIES') {
            $entityBodyStart = $i + 2
            for ($j = $entityBodyStart; $j -lt $pairs.Count; $j++) { if ($pairs[$j].Code -eq 0 -and $pairs[$j].Value.Trim() -eq 'ENDSEC') { $entityBodyEnd = $j; break } }
            break
        }
    }
    if ($entityBodyStart -lt 0 -or $entityBodyEnd -lt 0) { throw 'DXF ENTITIES section was not found.' }
    $entities = [System.Collections.Generic.List[object]]::new()
    $current = $null
    for ($i = $entityBodyStart; $i -lt $entityBodyEnd; $i++) {
        $pair = $pairs[$i]
        if ($pair.Code -eq 0) {
            if ($null -ne $current) { $entities.Add($current) }
            $current = [pscustomobject]@{ Type = $pair.Value.Trim(); Pairs = [System.Collections.Generic.List[object]]::new(); SourceIndex = $entities.Count }
            $current.Pairs.Add($pair)
        } elseif ($null -ne $current) { $current.Pairs.Add($pair) }
    }
    if ($null -ne $current) { $entities.Add($current) }
    return [pscustomobject]@{ File = $File; Encoding = $encoding; Pairs = $pairs; EntityBodyStart = $entityBodyStart; EntityBodyEnd = $entityBodyEnd; Entities = $entities; Parts = @(); FeatureRecords = @(); Stats = $null }
}

function Get-TextRecords {
    param([object]$Document)
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($entity in $Document.Entities) {
        if ($entity.Type -ne 'TEXT') { continue }
        $value = Get-FirstValue $entity 1
        if ($null -eq $value) { continue }
        $xValue = Get-FirstValue $entity 10; $yValue = Get-FirstValue $entity 20
        $x = $null; $y = $null
        if ($null -ne $xValue -and $null -ne $yValue) {
            try { $x = ConvertFrom-DxfNumber $xValue; $y = ConvertFrom-DxfNumber $yValue }
            catch { throw "TEXT '$value' has invalid insertion coordinates." }
        }
        $dim = Get-DimensionText $value
        $parsed = if ($null -eq $dim) { Read-FeatureLabel -Label $value }
        $isFeature = $null -ne $parsed
        if ($isFeature -and ($null -eq $x -or $null -eq $y)) {
            throw "Feature label '$value' has no valid insertion point (codes 10/20)."
        }
        $records.Add([pscustomobject]@{
            Value = $value.Trim(); X = $x; Y = $y
            Entity = $entity; EntityIndex = $entity.SourceIndex
            Dimension = $dim
            HasSH = [bool]($isFeature -and $parsed.HasSH)
            HasZ = [bool]($isFeature -and $parsed.HasZ)
            IsFeature = [bool]$isFeature; Parameters = $parsed; Shape = $null
        })
    }
    return ,$records.ToArray()
}

function Get-LayerTableInfo {
    param([System.Collections.Generic.List[object]]$Pairs)
    $tablesStart = -1; $tablesEnd = -1
    for ($i = 0; $i -lt ($Pairs.Count - 1); $i++) {
        if ($Pairs[$i].Code -eq 0 -and $Pairs[$i].Value.Trim() -eq 'SECTION' -and $Pairs[$i + 1].Code -eq 2 -and $Pairs[$i + 1].Value.Trim() -eq 'TABLES') {
            $tablesStart = $i + 2
            for ($j = $tablesStart; $j -lt $Pairs.Count; $j++) { if ($Pairs[$j].Code -eq 0 -and $Pairs[$j].Value.Trim() -eq 'ENDSEC') { $tablesEnd = $j; break } }
            break
        }
    }
    if ($tablesStart -lt 0 -or $tablesEnd -lt 0) { throw 'DXF TABLES section was not found.' }
    for ($i = $tablesStart; $i -lt ($tablesEnd - 1); $i++) {
        if ($Pairs[$i].Code -eq 0 -and $Pairs[$i].Value.Trim() -eq 'TABLE' -and $Pairs[$i + 1].Code -eq 2 -and $Pairs[$i + 1].Value.Trim() -eq 'LAYER') {
            $endTable = -1
            for ($j = $i + 2; $j -lt $tablesEnd; $j++) { if ($Pairs[$j].Code -eq 0 -and $Pairs[$j].Value.Trim() -eq 'ENDTAB') { $endTable = $j; break } }
            if ($endTable -lt 0) { throw 'The LAYER table has no ENDTAB marker.' }
            $firstEntry = $endTable
            for ($j = $i + 2; $j -lt $endTable; $j++) { if ($Pairs[$j].Code -eq 0 -and $Pairs[$j].Value.Trim() -eq 'LAYER') { $firstEntry = $j; break } }
            $countIndex = -1
            for ($j = $i + 2; $j -lt $firstEntry; $j++) { if ($Pairs[$j].Code -eq 70) { $countIndex = $j; break } }
            if ($countIndex -lt 0) { throw 'The LAYER table record count was not found.' }
            return [pscustomobject]@{ Start = $i; End = $endTable; CountIndex = $countIndex }
        }
    }
    throw 'DXF LAYER table was not found.'
}

function Test-LayerExists {
    param([System.Collections.Generic.List[object]]$Pairs, [string]$Name)
    $info = Get-LayerTableInfo $Pairs
    for ($i = $info.Start + 2; $i -lt $info.End; $i++) {
        if ($Pairs[$i].Code -eq 0 -and $Pairs[$i].Value.Trim() -eq 'LAYER') {
            for ($j = $i + 1; $j -lt $info.End -and $Pairs[$j].Code -ne 0; $j++) { if ($Pairs[$j].Code -eq 2 -and $Pairs[$j].Value.Trim() -eq $Name) { return $true } }
        }
    }
    return $false
}

function Add-Layer2 {
    param([System.Collections.Generic.List[object]]$Pairs, [string]$Handle)
    $info = Get-LayerTableInfo $Pairs
    $record = [System.Collections.Generic.List[object]]::new()
    Add-DxfPair $record 0 'LAYER'; Add-DxfPair $record 5 $Handle; Add-DxfPair $record 100 'AcDbSymbolTableRecord'; Add-DxfPair $record 100 'AcDbLayerTableRecord'; Add-DxfPair $record 2 '2'; Add-DxfPair $record 70 '0'; Add-DxfPair $record 62 '7'; Add-DxfPair $record 6 'CONTINUOUS'
    $oldCount = [int]::Parse($Pairs[$info.CountIndex].Value.Trim(), [System.Globalization.CultureInfo]::InvariantCulture)
    $Pairs[$info.CountIndex].Value = [string]($oldCount + 1)
    $Pairs.InsertRange($info.End, $record)
}

function Get-NextHandle {
    param([System.Collections.Generic.List[object]]$Pairs)
    [uint64]$maximum = 0
    foreach ($pair in $Pairs) {
        if ($pair.Code -eq 5 -or $pair.Code -eq 105) {
            $text = ([string]$pair.Value).Trim()
            if ($text -match '^[0-9A-Fa-f]+$') { try { [uint64]$value = [Convert]::ToUInt64($text, 16); if ($value -gt $maximum) { $maximum = $value } } catch {} }
        }
    }
    return [uint64]($maximum + 1)
}

function Update-Handseed {
    param([System.Collections.Generic.List[object]]$Pairs, [uint64]$NextHandle)
    $hex = $NextHandle.ToString('X')
    for ($i = 0; $i -lt ($Pairs.Count - 1); $i++) {
        if ($Pairs[$i].Code -eq 9 -and $Pairs[$i].Value.Trim() -eq '$HANDSEED' -and $Pairs[$i + 1].Code -eq 5) { $Pairs[$i + 1].Value = $hex; return }
    }
}

function Set-PolylineVertices {
    param([object]$Entity, [object[]]$Points)
    $old = @($Entity.Pairs.ToArray()); $firstX = -1; $lastY = -1
    for ($i = 0; $i -lt $old.Count; $i++) { if ($old[$i].Code -eq 10 -and $firstX -lt 0) { $firstX = $i }; if ($old[$i].Code -eq 20) { $lastY = $i } }
    if ($firstX -lt 0 -or $lastY -lt $firstX) { throw 'Target outline has no readable vertices.' }
    $vertexStarts = [System.Collections.Generic.List[int]]::new()
    for ($i = $firstX; $i -le $lastY; $i++) { if ($old[$i].Code -eq 10) { $vertexStarts.Add($i) } }
    if ($vertexStarts.Count -ne 4) { throw 'Target outline does not have exactly four original vertices.' }
    $counts = @{}
    foreach ($code in @(30,40,41,42)) { $counts[$code] = @($old | Where-Object { $_.Code -eq $code }).Count; if ($counts[$code] -ne 0 -and $counts[$code] -ne 4) { throw "Target outline has inconsistent per-vertex group $code data." } }
    $has30 = ($counts[30] -eq 4); $has40 = ($counts[40] -eq 4); $has41 = ($counts[41] -eq 4); $has42 = ($counts[42] -eq 4)
    $tailStart = $old.Count
    for ($i = $lastY + 1; $i -lt $old.Count; $i++) { if ($old[$i].Code -eq 210) { $tailStart = $i; break } }
    $vertexData = [System.Collections.Generic.List[object]]::new(); $hasIds = $false
    for ($vertexIndex = 0; $vertexIndex -lt 4; $vertexIndex++) {
        $start = $vertexStarts[$vertexIndex]; $next = if ($vertexIndex -lt 3) { $vertexStarts[$vertexIndex + 1] } else { $tailStart }
        if (($start + 1) -ge $old.Count -or $old[$start + 1].Code -ne 20) { throw 'Target outline vertex lacks Y coordinate.' }
        $id = $null
        for ($j = $start + 2; $j -lt $next; $j++) {
            $code = [int]$old[$j].Code
            if ($code -in @(30,40,41,42)) {
                $number = 0.0
                if (-not [double]::TryParse(([string]$old[$j].Value).Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or -not [double]::IsFinite($number)) { throw "Invalid per-vertex value (group $code)." }
                if ([math]::Abs($number) -gt 0.0000001) { if ($code -eq 30) { throw 'Target outline has non-zero vertex Z values.' }; throw "Target outline has non-zero width/bulge data (group $code); refusing to alter geometry." }
                continue
            }
            if ($code -eq 91) { if ($null -ne $id) { throw 'More than one vertex ID found.' }; $parsed = 0L; if (-not [long]::TryParse(([string]$old[$j].Value).Trim(), [ref]$parsed)) { throw 'Invalid vertex ID.' }; $id = $parsed; $hasIds = $true; continue }
            throw "Unsupported per-vertex DXF data (group $code); refusing to alter geometry."
        }
        $vertexData.Add([pscustomobject]@{ X = (ConvertFrom-DxfNumber $old[$start].Value); Y = (ConvertFrom-DxfNumber $old[$start + 1].Value); Id = $id })
    }
    if ($hasIds) { foreach ($v in $vertexData) { if ($null -eq $v.Id) { throw 'Only some vertices have group 91 identifiers.' } } }
    $maxId = -1L; if ($hasIds) { $maxId = [long](($vertexData | Measure-Object -Property Id -Maximum).Maximum) }
    $newPairs = [System.Collections.Generic.List[object]]::new(); $countFound = $false
    for ($i = 0; $i -lt $firstX; $i++) { $p = [pscustomobject]@{ Code = $old[$i].Code; CodeText = $old[$i].CodeText; Value = $old[$i].Value }; if ($p.Code -eq 90) { $p.Value = [string]$Points.Count; $countFound = $true }; $newPairs.Add($p) }
    if (-not $countFound) { throw 'Target outline has no vertex count field (group 90).' }
    foreach ($point in $Points) {
        Add-DxfPair $newPairs 10 (ConvertTo-DxfNumber ([double]$point.X)); Add-DxfPair $newPairs 20 (ConvertTo-DxfNumber ([double]$point.Y))
        if ($has30) { Add-DxfPair $newPairs 30 '0.000000' }; if ($has40) { Add-DxfPair $newPairs 40 '0.000000' }; if ($has41) { Add-DxfPair $newPairs 41 '0.000000' }; if ($has42) { Add-DxfPair $newPairs 42 '0.000000' }
        if ($hasIds) {
            $matches = @($vertexData | Where-Object { [math]::Abs($_.X - [double]$point.X) -lt 0.000001 -and [math]::Abs($_.Y - [double]$point.Y) -lt 0.000001 })
            if ($matches.Count -gt 1) { throw 'Replacement vertex matches multiple original vertex IDs.' }
            if ($matches.Count -eq 1) { Add-DxfPair $newPairs 91 ([string]$matches[0].Id) } else { $maxId++; Add-DxfPair $newPairs 91 ([string]$maxId) }
        }
    }
    for ($i = $tailStart; $i -lt $old.Count; $i++) { $newPairs.Add([pscustomobject]@{ Code = $old[$i].Code; CodeText = $old[$i].CodeText; Value = $old[$i].Value }) }
    $Entity.Pairs = $newPairs
}

function New-SlotLineEntity {
    param([string]$Handle, [string]$Edge, [object]$Shape, [double]$Offset)
    switch ($Edge) {
        'AB' { $x1 = $Shape.MinX; $y1 = $Shape.MaxY - $Offset; $x2 = $Shape.MaxX; $y2 = $y1 }
        'BC' { $x1 = $Shape.MaxX - $Offset; $y1 = $Shape.MinY; $x2 = $x1; $y2 = $Shape.MaxY }
        'CD' { $x1 = $Shape.MinX; $y1 = $Shape.MinY + $Offset; $x2 = $Shape.MaxX; $y2 = $y1 }
        'DA' { $x1 = $Shape.MinX + $Offset; $y1 = $Shape.MinY; $x2 = $x1; $y2 = $Shape.MaxY }
        default { throw "Unsupported groove edge '$Edge'." }
    }
    $entity = [pscustomobject]@{ Type = 'LINE'; Pairs = [System.Collections.Generic.List[object]]::new(); SourceIndex = -1 }
    Add-DxfPair $entity.Pairs 0 'LINE'; Add-DxfPair $entity.Pairs 5 $Handle; Add-DxfPair $entity.Pairs 100 'AcDbEntity'; Add-DxfPair $entity.Pairs 8 '2'; Add-DxfPair $entity.Pairs 100 'AcDbLine'
    Add-DxfPair $entity.Pairs 10 (ConvertTo-DxfNumber ([double]$x1)); Add-DxfPair $entity.Pairs 20 (ConvertTo-DxfNumber ([double]$y1)); Add-DxfPair $entity.Pairs 30 '0'
    Add-DxfPair $entity.Pairs 11 (ConvertTo-DxfNumber ([double]$x2)); Add-DxfPair $entity.Pairs 21 (ConvertTo-DxfNumber ([double]$y2)); Add-DxfPair $entity.Pairs 31 '0'
    return $entity
}
