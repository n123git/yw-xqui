Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if ($PSCommandPath) { # Works in both script form (.ps1) and compiled exe (PS2EXE)
    # PowerShell 3.0+ in script mode
    $basePath = Split-Path -Parent $PSCommandPath
} elseif ($MyInvocation.MyCommand.Path) {
    # Older PowerShell versions
    $basePath = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    # Fallback: current working directory
    $basePath = Get-Location
}


# Create Form
$form = New-Object System.Windows.Forms.Form
$form.Text = "XtractQuery GUI"
$form.Size = New-Object System.Drawing.Size(400,240)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false

# File Path TextBox
$txtFile = New-Object System.Windows.Forms.TextBox
$txtFile.Location = New-Object System.Drawing.Point(20,20)
$txtFile.Size = New-Object System.Drawing.Size(260,20)
$form.Controls.Add($txtFile)

# Browse Button
$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Browse"
$btnBrowse.Location = New-Object System.Drawing.Point(290,18)
$btnBrowse.Size = New-Object System.Drawing.Size(75,25)
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "XQ/CQ/XS Files|*.xq;*.xseq;*.cq;*.xs|All Files|*.*"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtFile.Text = $dlg.FileName
    }
})
$form.Controls.Add($btnBrowse)

# Decompile Button
$btnDecompile = New-Object System.Windows.Forms.Button
$btnDecompile.Text = "Decompile"
$btnDecompile.Location = New-Object System.Drawing.Point(10,60)
$btnDecompile.Size = New-Object System.Drawing.Size(110,30)
$form.Controls.Add($btnDecompile)


# Batch Decompile Button
$btnBatchDecompile = New-Object System.Windows.Forms.Button
$btnBatchDecompile.Text = "Batch Decompile from ZIP/XPCK"
$btnBatchDecompile.Location = New-Object System.Drawing.Point(140,60)
$btnBatchDecompile.Size = New-Object System.Drawing.Size(230,30)

$btnBatchDecompile.Add_Click({ # XPCK made this SO much more complicated :/ I had to parse the format, deal with string tables and even decompression because they decided itd be a great idea to compress the file names WHYY the files themselves arent compressed lol
    try {
        # --- helper: Try-DecompressLevel5 (methods: 0,1(LZ10),4(RLE),5(zlib) ) ---
        function Try-DecompressLevel5 {
            param([byte[]]$compSlice)
            if ($null -eq $compSlice -or $compSlice.Length -lt 4) { return $null }
            $header = [BitConverter]::ToUInt32($compSlice, 0)
            $method = $header -band 0x7
            $decompressedSize = [int]($header -shr 3)
            $compLen = $compSlice.Length - 4
            if ($compLen -le 0) { return $null }
            $comp = New-Object byte[] $compLen
            [System.Array]::Copy($compSlice, 4, $comp, 0, $compLen)

            switch ($method) {
                0 {
                    if ($decompressedSize -le 0 -or $decompressedSize -gt $comp.Length) { return $null }
                    $out = New-Object byte[] $decompressedSize
                    [System.Array]::Copy($comp, 0, $out, 0, $decompressedSize)
                    return $out
                }
                1 {
                    return LZ10-Decompress -comp $comp -expectedSize $decompressedSize
                }
                4 {
                    return RLE-PackBits-Decompress -comp $comp -expectedSize $decompressedSize
                }
                5 {
                    try {
                        # DeflateStream attempt (best-effort; too lazy to test)
                        $ms = New-Object System.IO.MemoryStream(,$comp)
                        $ds = New-Object System.IO.Compression.DeflateStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
                        $out = New-Object System.IO.MemoryStream
                        $buf = New-Object byte[] 8192
                        while (($r = $ds.Read($buf,0,$buf.Length)) -gt 0) { $out.Write($buf,0,$r) }
                        $ds.Close(); $ms.Close()
                        $res = $out.ToArray(); $out.Close()
                        return $res
                    } catch {
                        # try skipping 2-byte zlib header
                        try {
                            if ($comp.Length -gt 2) {
                                $ms2 = New-Object System.IO.MemoryStream(,$comp,2,$comp.Length-2,$false)
                                $ds2 = New-Object System.IO.Compression.DeflateStream($ms2, [System.IO.Compression.CompressionMode]::Decompress)
                                $out2 = New-Object System.IO.MemoryStream
                                $buf2 = New-Object byte[] 8192
                                while (($r2 = $ds2.Read($buf2,0,$buf2.Length)) -gt 0) { $out2.Write($buf2,0,$r2) }
                                $ds2.Close(); $ms2.Close()
                                $res2 = $out2.ToArray(); $out2.Close()
                                return $res2
                            } else { return $null }
                        } catch { return $null }
                    }
                }
                default { return $null } # unsupported (Huffman etc.)
            }
        }

        # --- helper: LZ10 decompress ---
        function LZ10-Decompress {
            param([byte[]]$comp,[int]$expectedSize)
            if ($null -eq $comp -or $comp.Length -eq 0) { return New-Object byte[] 0 }
            $inPos = 0
            if ($comp.Length -ge 4 -and $comp[0] -eq 0x10) { $inPos = 4 }
            if ($expectedSize -le 0) { $expectedSize = 0 }
            $out = New-Object byte[] $expectedSize
            $outPos = 0
            while ($outPos -lt $expectedSize) {
                if ($inPos -ge $comp.Length) { break }
                $flag = $comp[$inPos]; $inPos++
                for ($bit=7; $bit -ge 0; $bit--) {
                    if ($outPos -ge $expectedSize) { break }
                    $isCompressed = ((($flag -shr $bit) -band 1) -eq 1)
                    if ($isCompressed) {
                        if ($inPos + 1 -ge $comp.Length) { break }
                        $b1 = $comp[$inPos]; $inPos++
                        $b2 = $comp[$inPos]; $inPos++
                        $length = (($b1 -shr 4) -bor 0) + 3
                        $disp = ((($b1 -band 0x0F) -shl 8) -bor $b2)
                        $src = $outPos - ($disp + 1)
                        if ($src -lt 0) { $src = 0 }
                        for ($k=0; $k -lt $length -and $outPos -lt $expectedSize; $k++) {
                            if ($src -lt 0 -or $src -ge $out.Length) { $out[$outPos] = 0 } else { $out[$outPos] = $out[$src] }
                            $outPos++; $src++
                        }
                    } else {
                        if ($inPos -ge $comp.Length) { break }
                        $out[$outPos] = $comp[$inPos]; $inPos++; $outPos++
                    }
                }
            }
            return $out
        }

        # --- helper: RLE PackBits decompress (port of rle_packbits_decompress) ---
        function RLE-PackBits-Decompress {
            param([byte[]]$comp,[int]$expectedSize)
            $input = $comp
            $out = New-Object byte[] $expectedSize
            $inPos = 0
            $outPos = 0
            while ($outPos -lt $expectedSize -and $inPos -lt $input.Length) {
                $flag = $input[$inPos]; $inPos++
                if (($flag -band 0x80) -ne 0) {
                    if ($inPos -ge $input.Length) { break }
                    $val = $input[$inPos]; $inPos++
                    $repetitions = ($flag -band 0x7F) + 3
                    $remaining = $expectedSize - $outPos
                    $count = [Math]::Min($repetitions, $remaining)
                    for ($i=0; $i -lt $count; $i++) { $out[$outPos++] = $val }
                } else {
                    $length = $flag + 1
                    $remaining = $expectedSize - $outPos
                    $count = [Math]::Min($length, $remaining)
                    for ($i=0; $i -lt $count; $i++) {
                        if ($inPos -ge $input.Length) { break }
                        $out[$outPos++] = $input[$inPos++]
                    }
                }
            }
            return $out
        }

        # ----------------- main handler start (wow :0) -----------------
$dlg = New-Object System.Windows.Forms.OpenFileDialog
$dlg.Filter = "Archives|*.zip;*.xa;*.xr;*.pck;*.xc|All Files|*.*"
$result = $dlg.ShowDialog()

# Check both dialog result and that a file was actually selected
if ($result -ne [System.Windows.Forms.DialogResult]::OK -or [string]::IsNullOrWhiteSpace($dlg.FileName)) {
    [System.Windows.Forms.MessageBox]::Show("No file selected for batch decompile.")
    return
}

$archiveFile = $dlg.FileName
if (-not (Test-Path $archiveFile)) {
    [System.Windows.Forms.MessageBox]::Show("Please select a valid archive!")
    return
}

        $exe = Join-Path $basePath "XtractQuery.exe"
        $workingOutDir = Join-Path $basePath "BatchDecompile"
        if (-not (Test-Path $workingOutDir)) { New-Item -ItemType Directory -Path $workingOutDir | Out-Null }

        $bytes = [System.IO.File]::ReadAllBytes($archiveFile)
        if ($bytes.Length -lt 4) { [System.Windows.Forms.MessageBox]::Show("File too small."); return }

        $isZip = ($bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B) # PK
        $magicStr = [System.Text.Encoding]::ASCII.GetString($bytes,0,4)
        $xpckMagics = @('XPCK') # I was going to make this array for ZIP and XPCK but im too lazy to change all the logic :/
        $isXpck = $xpckMagics -contains $magicStr

        $extractedFiles = New-Object System.Collections.Generic.List[string]

        if ($isZip) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::OpenRead($archiveFile)
            foreach ($entry in $zip.Entries) {
                if ($entry.Length -le 0) { continue }
                $safeName = [System.IO.Path]::GetFileName($entry.FullName)
                if ([string]::IsNullOrWhiteSpace($safeName)) { continue }
                $outFile = Join-Path $workingOutDir $safeName
                $parent = [System.IO.Path]::GetDirectoryName($outFile)
                if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
                try { $entry.ExtractToFile($outFile,$true) } catch {
                    $stream = $entry.Open(); $buf = New-Object byte[] $entry.Length; $read=0
                    while ($read -lt $entry.Length) { $r = $stream.Read($buf,$read,[int]($entry.Length-$read)); if ($r -le 0) { break }; $read += $r }
                    $stream.Close(); [System.IO.File]::WriteAllBytes($outFile,$buf)
                }
                $extractedFiles.Add($outFile) | Out-Null
            }
            $zip.Dispose()
        } elseif ($isXpck) {
            $ms = New-Object System.IO.MemoryStream(,$bytes)
            $br = New-Object System.IO.BinaryReader($ms)
            # read header fields at offsets 4..19 (0..3 is XPCK magic lol)
            $ms.Position = 4
            if ($ms.Length -lt 20) { [System.Windows.Forms.MessageBox]::Show("XPCK header too small"); return }
            $fileCountAndType = $br.ReadUInt16()
            $infoOffset = $br.ReadUInt16()
            $nameTableOffset = $br.ReadUInt16()
            $dataOffset = $br.ReadUInt16()
            $infoSize = $br.ReadUInt16()
            $nameTableSize = $br.ReadUInt16()
            $dataSize = $br.ReadUInt32()

            $fileCount = $fileCountAndType -band 0x0FFF
            $infoByteOffset = $infoOffset * 4
            $nameByteOffset = $nameTableOffset * 4
            $dataByteOffset = $dataOffset * 4
            $nameByteSize = $nameTableSize * 4

            # prepare compressed name table slice if present
            $compNameSlice = $null
            if ($nameByteOffset -ge 0 -and $nameByteOffset -lt $bytes.Length -and $nameByteSize -gt 0) {
                $safeLen = [Math]::Min($nameByteSize, $bytes.Length - $nameByteOffset)
                $compNameSlice = New-Object byte[] $safeLen
                [System.Array]::Copy($bytes, $nameByteOffset, $compNameSlice, 0, $safeLen)
            }

            # try to decompress name table (if exists)
            $useSequentialNames = $true
            $decompressedNameTable = $null
            if ($compNameSlice -ne $null -and $compNameSlice.Length -ge 4) {
                $maybe = Try-DecompressLevel5 -compSlice $compNameSlice
                if ($maybe -ne $null) {
                    $decompressedNameTable = $maybe
                    $useSequentialNames = $false
                } else {
                    [System.Windows.Forms.MessageBox]::Show("Unsupported compression for name table; defaulting to YYY.bin for all files")
                    $useSequentialNames = $true
                }
            } else {
                $useSequentialNames = $true
            }

            # iterate entries (12 bytes each)
            $counter = 0
            for ($i=0; $i -lt $fileCount; $i++) {
                $entryPos = $infoByteOffset + ($i * 12)
                if ($entryPos + 12 -gt $bytes.Length) { break }

                $ms.Position = $entryPos
                $hash = $br.ReadUInt32()
                $nameOffset = $br.ReadUInt16()
                $fileOffsetLower = $br.ReadUInt16()
                $fileSizeLower = $br.ReadUInt16()
                $fileOffsetUpper = $br.ReadByte()
                $fileSizeUpper = $br.ReadByte()

                $fileOffsetCombined = ( ($fileOffsetUpper -shl 16) -bor $fileOffsetLower ) -band 0xFFFFFFFF
                $fileOffset = [int]($fileOffsetCombined -shl 2)
                $fileSize = ( ($fileSizeUpper -shl 16) -bor $fileSizeLower ) -band 0xFFFFFFFF
                if ($fileSize -le 0) { continue }
                if ($dataByteOffset + $fileOffset + $fileSize -gt $bytes.Length -or $dataByteOffset + $fileOffset -lt 0) { continue }

                $fileData = New-Object byte[] $fileSize
                [System.Array]::Copy($bytes, $dataByteOffset + $fileOffset, $fileData, 0, $fileSize)

                # determine filename
                if (-not $useSequentialNames -and $decompressedNameTable -ne $null) {
                    $name = $null
                    if ($nameOffset -ge 0 -and $nameOffset -lt $decompressedNameTable.Length) {
                        $end = $nameOffset
                        while ($end -lt $decompressedNameTable.Length -and $decompressedNameTable[$end] -ne 0) { $end++ }
                        $len = $end - $nameOffset
                        if ($len -gt 0) {
                            $tmp = New-Object byte[] $len
                            [System.Array]::Copy($decompressedNameTable, $nameOffset, $tmp, 0, $len)
                            try { $name = [System.Text.Encoding]::GetEncoding(932).GetString($tmp).Trim() } catch { $name = [System.Text.Encoding]::ASCII.GetString($tmp).Trim() }
                        }
                    }
                    if ([string]::IsNullOrWhiteSpace($name)) { $name = "{0:D3}.bin" -f $counter }
                    else {
                        # sanitize
                        $invalid = [System.IO.Path]::GetInvalidFileNameChars()
                        foreach ($c in $invalid) { $name = $name.Replace($c, '_') }
                        if ([string]::IsNullOrWhiteSpace($name)) { $name = "{0:D3}.bin" -f $counter }
                    }
                    $safeName = $name
                } else {
                    $safeName = "{0:D3}.bin" -f $counter
                }

                $outFile = Join-Path $workingOutDir $safeName
                $parent = [System.IO.Path]::GetDirectoryName($outFile)
                if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
                [System.IO.File]::WriteAllBytes($outFile, $fileData)
                $extractedFiles.Add($outFile) | Out-Null
                $counter++
            }

            $br.Close()
            $ms.Close()
        } else {
            [System.Windows.Forms.MessageBox]::Show("Unsupported archive type (magic: $magicStr)")
            return
        }

        if ($extractedFiles.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("No files were extracted from the archive."); return }

        # Decompile files that have script magics at start
        $scriptMagics = @('XSEQ','XQ32','XSCR','GSS1') # I even decided to include GGS1 here too
        $decompiled = 0
        foreach ($f in $extractedFiles) {
            try {
                if (-not (Test-Path $f)) { continue }
                $fs = [System.IO.File]::OpenRead($f)
                $hdr = New-Object byte[] ( [Math]::Min(4, $fs.Length) )
                $fs.Read($hdr,0,$hdr.Length) | Out-Null
                $fs.Close()
                if ($hdr.Length -eq 0) { continue }
                $hdrStr = [System.Text.Encoding]::ASCII.GetString($hdr,0,$hdr.Length)
                foreach ($m in $scriptMagics) {
                    if ($hdrStr.StartsWith($m)) {
                        $psi = New-Object System.Diagnostics.ProcessStartInfo
                        $psi.FileName = $exe
                        $psi.Arguments = "-o e -f `"$f`""
                        $psi.WorkingDirectory = $basePath
                        $psi.UseShellExecute = $false
                        $proc = [System.Diagnostics.Process]::Start($psi)
                        $proc.WaitForExit()
                        $decompiled++
                        break
                    }
                }
            } catch {
                # per-file errors ignored
            }
        }

        [System.Windows.Forms.MessageBox]::Show("Done. Extracted File Count: $($extractedFiles.Count). Decompiled Script Count: $decompiled")
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Batch error: $($_.Exception.Message)")
    }
})


$form.Controls.Add($btnBatchDecompile)

# Status Label
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(25, 180)
$statusLabel.Size = New-Object System.Drawing.Size([int]($form.Width - 20),20)
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$form.Controls.Add($statusLabel)

# Compilation Label with Lines
$lblWidth = 120
$lblX = [int]( $form.ClientSize.Width - $lblWidth ) / 2

# Left line
$lineLeft = New-Object System.Windows.Forms.Label
$lineLeft.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
$lineLeft.Location = New-Object System.Drawing.Point(10,110)
$lineLeft.Size = New-Object System.Drawing.Size([int]($lblX - 10),2)
$form.Controls.Add($lineLeft)

# Label
$lblCompilation = New-Object System.Windows.Forms.Label
$lblCompilation.Text = "Compilation"
$lblCompilation.Location = New-Object System.Drawing.Point($lblX,100)
$lblCompilation.Size = New-Object System.Drawing.Size($lblWidth,20)
$lblCompilation.Font = New-Object System.Drawing.Font("Microsoft Sans Serif",10,[System.Drawing.FontStyle]::Regular)
$lblCompilation.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$form.Controls.Add($lblCompilation)

# Right line
$lineRight = New-Object System.Windows.Forms.Label
$lineRight.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
$lineRight.Location = New-Object System.Drawing.Point([int]($lblX + $lblWidth + 5),110)
$lineRight.Size = New-Object System.Drawing.Size([int]($form.ClientSize.Width - ($lblX + $lblWidth + 15)),2)
$form.Controls.Add($lineRight)

# Compile Buttons
$btnCompileXSEQ = New-Object System.Windows.Forms.Button
$btnCompileXSEQ.Text = "Compile XSEQ"
$btnCompileXSEQ.Size = New-Object System.Drawing.Size(110,30)
$form.Controls.Add($btnCompileXSEQ)

$btnCompileXQ32 = New-Object System.Windows.Forms.Button
$btnCompileXQ32.Text = "Compile XQ32"
$btnCompileXQ32.Size = New-Object System.Drawing.Size(110,30)
$form.Controls.Add($btnCompileXQ32)

$btnCompileXSCR = New-Object System.Windows.Forms.Button
$btnCompileXSCR.Text = "Compile XSCR"
$btnCompileXSCR.Size = New-Object System.Drawing.Size(110,30)
$form.Controls.Add($btnCompileXSCR)

# Evenly space compile buttons
$compileButtons = @($btnCompileXSEQ, $btnCompileXQ32, $btnCompileXSCR)
$buttonWidth = 110
$buttonSpacing = ($form.ClientSize.Width - ($compileButtons.Count * $buttonWidth)) / ($compileButtons.Count + 1)
for ($i=0; $i -lt $compileButtons.Count; $i++) {
    $compileButtons[$i].Location = New-Object System.Drawing.Point(
        [int](($i+1)*$buttonSpacing + $i*$buttonWidth), 140)
}

# Tooltips
$tooltip = New-Object System.Windows.Forms.ToolTip
$tooltip.SetToolTip($btnDecompile, "Decompile selected file to human-readable text")
$tooltip.SetToolTip($btnCompileXSEQ, "Compile text to XSEQ file (.xq/.xseq)")
$tooltip.SetToolTip($btnCompileXQ32, "Compile text to XQ32 file (.xq)")
$tooltip.SetToolTip($btnCompileXSCR, "Compile text to XSCR file (.xs)")

# Button Click Events
# Define your external EXE path
$exePath = Join-Path $basePath "XtractQuery.exe"


$btnDecompile.Add_Click({
    if (-not (Test-Path $txtFile.Text)) { [System.Windows.Forms.MessageBox]::Show("Please select a valid file!"); return }
    & $exePath -o e -f $txtFile.Text
    $statusLabel.Text = "Decompiled successfully!"
})

$btnCompileXSEQ.Add_Click({
    if (-not (Test-Path $txtFile.Text)) { [System.Windows.Forms.MessageBox]::Show("Please select a valid file!"); return }
    & $exePath -o c -t xseq -f $txtFile.Text
    $statusLabel.Text = "Compiled to XSEQ successfully!"
})

$btnCompileXQ32.Add_Click({
    if (-not (Test-Path $txtFile.Text)) { [System.Windows.Forms.MessageBox]::Show("Please select a valid file!"); return }
    & $exePath -o c -t xq32 -f $txtFile.Text
    $statusLabel.Text = "Compiled to XQ32 successfully!"
})

$btnCompileXSCR.Add_Click({
    if (-not (Test-Path $txtFile.Text)) { [System.Windows.Forms.MessageBox]::Show("Please select a valid file!"); return }
    & $exePath -o c -t xscr -f $txtFile.Text
    $statusLabel.Text = "Compiled to XSCR successfully!"
})

# Show Form
$form.Topmost = $true
$form.Add_Shown({$form.Activate()})
[void]$form.ShowDialog()
