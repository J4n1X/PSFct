#Requires -Version 5.1
Set-StrictMode -Version Latest

function Assert-FctMagic {
    param([byte[]] $Bytes)
    if ($Bytes.Length -lt 3 -or
        $Bytes[0] -ne 0x46 -or
        $Bytes[1] -ne 0x43 -or
        $Bytes[2] -ne 0x54) {
        throw [System.IO.InvalidDataException]::new(
            "File is not a valid FCT archive (bad magic bytes)."
        )
    }
}

# [IO.Path]::GetRelativePath exists only in .NET Core 2+ (PS 6+);
# fall back to URI arithmetic on .NET Framework (PS 5.1).
function Resolve-FctStoredPath {
    param([string] $RootDir, [string] $FilePath)

    $root = [System.IO.Path]::GetFullPath($RootDir)
    $file = [System.IO.Path]::GetFullPath($FilePath)

    if ([System.IO.Path] | Get-Member -Static -Name 'GetRelativePath' -ErrorAction SilentlyContinue) {
        $rel = [System.IO.Path]::GetRelativePath($root, $file)
    }
    else {
        $sep     = [System.IO.Path]::DirectorySeparatorChar
        $rootUri = [System.Uri]::new($root.TrimEnd($sep) + $sep)
        $fileUri = [System.Uri]::new($file)
        $rel     = [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($fileUri).ToString())
        $rel     = $rel -replace '/', [string]$sep
    }

    return $rel -replace '\\', '/'   # always forward slashes in the archive
}

function Read-FctIndex {
    param([string] $ArchivePath)

    $stream = [System.IO.File]::OpenRead($ArchivePath)
    try {
        $reader = [System.IO.BinaryReader]::new(
            $stream, [System.Text.Encoding]::UTF8, $true   # leaveOpen
        )
        try {
            $magic = $reader.ReadBytes(3)
            Assert-FctMagic $magic
            $chunkSize = $reader.ReadUInt16()   # little-endian

            $entries       = [System.Collections.Generic.List[PSObject]]::new()
            $oneBasedIndex = 1

            while ($stream.Position -lt $stream.Length) {
                $headerStart = $stream.Position

                $chunkCount           = $reader.ReadUInt32()   # 4 bytes LE
                $lastChunkContentSize = $reader.ReadUInt16()   # 2 bytes LE
                $filePathSize         = $reader.ReadUInt16()   # 2 bytes LE
                $pathBytes            = $reader.ReadBytes([int]$filePathSize)
                $formattedFilePath    = [System.Text.Encoding]::UTF8.GetString($pathBytes)

                if ($lastChunkContentSize -gt $chunkSize -or $filePathSize -gt 65526) {
                    throw [System.IO.InvalidDataException]::new(
                        "Corrupt FCT file header at byte offset $headerStart."
                    )
                }

                $dataOffset = $stream.Position
                $headerSize = $dataOffset - $headerStart
                $fileSize   = [uint64]$chunkCount * [uint64]$chunkSize +
                              [uint64]$lastChunkContentSize
                $extraChunk = if ($lastChunkContentSize -ne 0) { [uint64]1 } else { [uint64]0 }
                $dataBytes  = ([uint64]$chunkCount + $extraChunk) * [uint64]$chunkSize

                $entries.Add([PSCustomObject]@{
                    Index                = $oneBasedIndex
                    FormattedFilePath    = $formattedFilePath
                    FileSize             = $fileSize
                    ChunkCount           = $chunkCount
                    LastChunkContentSize = $lastChunkContentSize
                    HeaderStart          = $headerStart
                    HeaderSize           = $headerSize
                    DataOffset           = $dataOffset
                    DataBytes            = $dataBytes
                    ChunkSize            = $chunkSize
                })

                $oneBasedIndex++
                $stream.Seek([int64]$dataBytes, [System.IO.SeekOrigin]::Current) | Out-Null
            }

            return @{ ChunkSize = $chunkSize; Entries = $entries }
        }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Write-FctFileEntry {
    param(
        [System.IO.BinaryWriter] $Writer,
        [string]  $FormattedFilePath,
        [string]  $SourcePath,
        [uint16]  $ChunkSize,
        [int]     $ProgressId       = -1,   # -1 = no inner progress bar
        [int]     $ProgressParentId = -1
    )

    $fileSize             = [System.IO.FileInfo]::new($SourcePath).Length
    $chunkCount           = [uint32][Math]::Floor($fileSize / $ChunkSize)
    $lastChunkContentSize = [uint16]($fileSize % $ChunkSize)
    $pathBytes            = [System.Text.Encoding]::UTF8.GetBytes($FormattedFilePath)
    $filePathLen          = [uint16]$pathBytes.Length

    if ($filePathLen -gt 65526) {
        throw [System.ArgumentException]::new(
            "Stored path '$FormattedFilePath' exceeds the 65526-byte maximum."
        )
    }

    $Writer.Write([uint32]$chunkCount)            # 4 bytes LE
    $Writer.Write([uint16]$lastChunkContentSize)  # 2 bytes LE
    $Writer.Write([uint16]$filePathLen)           # 2 bytes LE
    $Writer.Write($pathBytes)                     # UTF-8, no null terminator

    $extraChunk  = if ($lastChunkContentSize -ne 0) { 1 } else { 0 }
    $totalChunks = [int]$chunkCount + $extraChunk
    $chunksDone  = 0

    $buffer   = [byte[]]::new($ChunkSize)
    $inStream = [System.IO.File]::OpenRead($SourcePath)
    $sw       = if ($ProgressId -ge 0) { [System.Diagnostics.Stopwatch]::StartNew() } else { $null }
    try {
        while ($true) {
            [Array]::Clear($buffer, 0, $buffer.Length)
            $bytesRead = $inStream.Read($buffer, 0, [int]$ChunkSize)
            if ($bytesRead -eq 0) { break }
            $Writer.Write($buffer)   # always ChunkSize bytes; tail zeros = padding

            $chunksDone++
            if ($sw -and $totalChunks -gt 0 -and $sw.ElapsedMilliseconds -ge 100) {
                Write-Progress -Id $ProgressId -ParentId $ProgressParentId `
                    -Activity        $FormattedFilePath `
                    -Status          "Chunk $chunksDone / $totalChunks" `
                    -PercentComplete ([int]($chunksDone / $totalChunks * 100))
                $sw.Restart()
            }
        }
    }
    finally { $inStream.Dispose() }
}

function Expand-InputPaths {
    param([string[]] $Paths, [string] $RootDirectory)

    foreach ($inputPath in $Paths) {
        $inputPath = [System.IO.Path]::GetFullPath($inputPath)

        if ([System.IO.Directory]::Exists($inputPath)) {
            $rootDir = if ($RootDirectory) {
                [System.IO.Path]::GetFullPath($RootDirectory)
            } else { $inputPath }

            $files = [System.IO.Directory]::GetFiles(
                $inputPath, '*', [System.IO.SearchOption]::AllDirectories
            )
            foreach ($f in $files) {
                [PSCustomObject]@{ File = $f; RootDir = $rootDir }
            }
        }
        elseif ([System.IO.File]::Exists($inputPath)) {
            $rootDir = if ($RootDirectory) {
                [System.IO.Path]::GetFullPath($RootDirectory)
            } else {
                [System.IO.Path]::GetDirectoryName($inputPath)
            }
            [PSCustomObject]@{ File = $inputPath; RootDir = $rootDir }
        }
        else {
            throw [System.IO.FileNotFoundException]::new(
                "Path not found: $inputPath", $inputPath
            )
        }
    }
}

function Select-FctEntries {
    param($Entries, [uint32[]] $Index)
    if (-not $Index -or $Index.Length -eq 0) { return $Entries }
    $Entries | Where-Object { $_.Index -in $Index }
}

function Format-FctFileSize {
    param([uint64] $Bytes)
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N1} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}


function New-FctArchive {
    <#
    .SYNOPSIS
        Creates a new, empty FCT archive.

    .DESCRIPTION
        Writes the 5-byte FCT archive header:
          Bytes 0-2 : magic "FCT" (0x46 0x43 0x54)
          Bytes 3-4 : ChunkSize as little-endian uint16

    .PARAMETER Path
        Destination path for the new archive file.

    .PARAMETER ChunkSize
        Size in bytes of every data chunk. Range: 1–65535. Default: 4096.

    .PARAMETER Force
        Overwrite the file if it already exists.

    .EXAMPLE
        New-FctArchive ./data.fct -ChunkSize 8192

    .EXAMPLE
        New-FctArchive ./backup.fct
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Path,

        [Parameter(Position = 1)]
        [ValidateRange(1, 65535)]
        [uint16] $ChunkSize = 4096,

        [switch] $Force
    )

    $resolved = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)

    if ([System.IO.File]::Exists($resolved) -and -not $Force) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.IOException]::new(
                    "'$resolved' already exists. Use -Force to overwrite."
                ),
                'FctFileExists',
                [System.Management.Automation.ErrorCategory]::ResourceExists,
                $resolved
            )
        )
    }

    if ($PSCmdlet.ShouldProcess($resolved, 'Create FCT archive')) {
        $stream = [System.IO.File]::Open(
            $resolved, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write
        )
        try {
            $writer = [System.IO.BinaryWriter]::new($stream)
            try {
                $writer.Write([byte]0x46)
                $writer.Write([byte]0x43)
                $writer.Write([byte]0x54)
                $writer.Write([uint16]$ChunkSize)   # little-endian
            }
            finally { $writer.Dispose() }
        }
        finally { $stream.Dispose() }

        Write-Verbose "Created FCT archive '$resolved' (ChunkSize=$ChunkSize)."
        [System.IO.FileInfo]::new($resolved)
    }
}


function Get-FctItem {
    <#
    .SYNOPSIS
        Lists entries stored inside an FCT archive.

    .DESCRIPTION
        Returns one object per archive entry describing its index, stored
        path, file size, and chunk layout. No data is extracted.

        Output objects include ArchivePath so they can be piped directly into
        Expand-FctArchive or Remove-FctItem.

    .PARAMETER Path
        Path to the FCT archive.

    .PARAMETER Filter
        Wildcard pattern matched against the stored EntryPath.
        Supports * (any characters) and ? (single character).
        The match is case-insensitive and applies to the full forward-slash
        path as stored in the archive (e.g. "src/*.txt", "readme*").

    .PARAMETER Index
        One or more 1-based indices. When specified only those entries are
        returned. Can be combined with -Filter.

    .EXAMPLE
        Get-FctItem ./data.fct

    .EXAMPLE
        Get-FctItem ./data.fct -Filter "*.txt"

    .EXAMPLE
        Get-FctItem ./data.fct -Filter "src/*"

    .EXAMPLE
        Get-FctItem ./data.fct -Filter "*.log" | Remove-FctItem

    .EXAMPLE
        Get-FctItem ./data.fct -Index 1, 3
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0,
                   ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'LiteralPath', 'ArchivePath')]
        [string] $Path,

        [Parameter(Position = 1)]
        [SupportsWildcards()]
        [string] $Filter,

        [Parameter()]
        [uint32[]] $Index
    )

    process {
        $resolved = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
        $info     = Read-FctIndex -ArchivePath $resolved
        $entries  = Select-FctEntries -Entries $info.Entries -Index $Index

        if ($Filter) {
            $pattern = [System.Management.Automation.WildcardPattern]::new(
                $Filter,
                [System.Management.Automation.WildcardOptions]::IgnoreCase
            )
            $entries = $entries | Where-Object { $pattern.IsMatch($_.FormattedFilePath) }
        }

        foreach ($e in $entries) {
            [PSCustomObject]@{
                PSTypeName           = 'FCT.ArchiveEntry'
                Index                = $e.Index
                EntryPath            = $e.FormattedFilePath
                FileSize             = $e.FileSize
                ChunkCount           = $e.ChunkCount
                LastChunkContentSize = $e.LastChunkContentSize
                ChunkSize            = $e.ChunkSize
                ArchivePath          = $resolved   # binds $Path on downstream cmdlets
            }
        }
    }
}


function Add-FctItem {
    <#
    .SYNOPSIS
        Adds files or directories to an existing FCT archive.

    .DESCRIPTION
        Appends each file to the end of the archive. Directories are
        traversed recursively. The path stored in the archive is computed
        relative to RootDirectory (default: the item's parent directory for
        files, or the directory itself for directories).

    .PARAMETER Path
        Path to the FCT archive.

    .PARAMETER ItemPath
        One or more file or directory paths to add. Accepts pipeline input.

    .PARAMETER RootDirectory
        Override the root used when computing stored relative paths.

    .EXAMPLE
        Add-FctItem ./backup.fct ./src

    .EXAMPLE
        Add-FctItem ./backup.fct ./README.md, ./LICENSE

    .EXAMPLE
        Get-ChildItem *.txt | Add-FctItem -Path ./backup.fct
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Path,

        [Parameter(Mandatory, Position = 1,
                   ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string[]] $ItemPath,

        [Parameter()]
        [string] $RootDirectory
    )

    begin {
        $resolved    = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
        $headerBytes = [byte[]]::new(5)
        $peekStream  = [System.IO.File]::OpenRead($resolved)
        try { $peekStream.Read($headerBytes, 0, 5) | Out-Null }
        finally { $peekStream.Dispose() }

        Assert-FctMagic $headerBytes
        $chunkSize = [uint16]([uint16]$headerBytes[3] -bor ([uint16]$headerBytes[4] -shl 8))

        # Collect all pairs before opening the writer so we know the total
        # count upfront — needed for accurate progress percentage.
        $allPairs = [System.Collections.Generic.List[PSObject]]::new()
    }

    process {
        foreach ($item in $ItemPath) {
            $itemResolved = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($item)
            $rootOverride = if ($RootDirectory) {
                $PSCmdlet.GetUnresolvedProviderPathFromPSPath($RootDirectory)
            } else { $null }

            try {
                $expanded = @(Expand-InputPaths -Paths @($itemResolved) -RootDirectory $rootOverride)
            }
            catch {
                $PSCmdlet.WriteError(
                    [System.Management.Automation.ErrorRecord]::new(
                        $_.Exception,
                        'FctItemNotFound',
                        [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                        $item
                    )
                )
                continue
            }

            foreach ($pair in $expanded) {
                $allPairs.Add([PSCustomObject]@{
                    StoredPath = Resolve-FctStoredPath -RootDir $pair.RootDir -FilePath $pair.File
                    File       = $pair.File
                    FileSize   = [System.IO.FileInfo]::new($pair.File).Length
                })
            }
        }
    }

    end {
        $total     = $allPairs.Count
        $outStream = [System.IO.File]::Open(
            $resolved, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write
        )
        $writer = [System.IO.BinaryWriter]::new(
            $outStream, [System.Text.Encoding]::UTF8, $true
        )
        try {
            for ($n = 0; $n -lt $total; $n++) {
                $pair    = $allPairs[$n]
                $sizeStr = Format-FctFileSize $pair.FileSize

                Write-Progress -Id 1 `
                    -Activity        'Adding files to FCT archive' `
                    -Status          "[$($n + 1) / $total] $($pair.StoredPath) ($sizeStr)" `
                    -PercentComplete ([int](($n / [Math]::Max($total, 1)) * 100))

                if ($PSCmdlet.ShouldProcess($pair.File, "Add to FCT archive as '$($pair.StoredPath)'")) {
                    Write-Verbose "Adding '$($pair.StoredPath)' ($($pair.FileSize) bytes)."
                    try {
                        Write-FctFileEntry -Writer $writer `
                            -FormattedFilePath $pair.StoredPath `
                            -SourcePath        $pair.File `
                            -ChunkSize         $chunkSize `
                            -ProgressId        2 `
                            -ProgressParentId  1
                    }
                    catch {
                        $PSCmdlet.WriteError(
                            [System.Management.Automation.ErrorRecord]::new(
                                $_.Exception,
                                'FctWriteError',
                                [System.Management.Automation.ErrorCategory]::WriteError,
                                $pair.File
                            )
                        )
                    }
                    finally {
                        Write-Progress -Id 2 -Activity $pair.StoredPath -Completed
                    }
                }
            }
        }
        finally {
            Write-Progress -Id 1 -Activity 'Adding files to FCT archive' -Completed
            $writer.Dispose()
            $outStream.Dispose()
        }
    }
}


function Expand-FctArchive {
    <#
    .SYNOPSIS
        Extracts files from an FCT archive.

    .DESCRIPTION
        Extracts all (or selected) entries into DestinationPath, recreating
        the stored directory structure. Partial last chunks are trimmed to
        their real byte count on write.

        Can be piped from Get-FctItem: the ArchivePath property supplies the
        archive location and Index supplies which entries to extract.

    .PARAMETER Path
        Path to the FCT archive.

    .PARAMETER DestinationPath
        Root directory to extract files into.

    .PARAMETER Index
        One or more 1-based indices to extract. When omitted all files are
        extracted. Automatically bound from Get-FctItem pipeline output.

    .PARAMETER Force
        Overwrite existing output files.

    .EXAMPLE
        Expand-FctArchive ./backup.fct ./output

    .EXAMPLE
        Expand-FctArchive ./backup.fct ./output -Index 1, 3

    .EXAMPLE
        Get-FctItem ./backup.fct | Where-Object EntryPath -like 'src/*' |
            Expand-FctArchive -DestinationPath ./output
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0,
                   ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'LiteralPath', 'ArchivePath')]
        [string] $Path,

        [Parameter(Mandatory, Position = 1)]
        [string] $DestinationPath,

        [Parameter(ValueFromPipelineByPropertyName)]
        [uint32[]] $Index,

        [switch] $Force
    )

    begin {
        $destResolved    = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($DestinationPath)
        $pipelineIndices = [System.Collections.Generic.List[uint32]]::new()
        $lastArchivePath = $null
    }

    process {
        $resolved        = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
        $lastArchivePath = $resolved

        if ($Index -and $Index.Length -gt 0) {
            foreach ($i in $Index) { $pipelineIndices.Add([uint32]$i) }
        }
    }

    end {
        if (-not $lastArchivePath) { return }

        $info      = Read-FctIndex -ArchivePath $lastArchivePath
        $chunkSize = [int]$info.ChunkSize
        $idxArr    = if ($pipelineIndices.Count -gt 0) { [uint32[]]$pipelineIndices } else { @() }
        $entries   = @(Select-FctEntries -Entries $info.Entries -Index $idxArr)
        $total     = $entries.Count

        if (-not [System.IO.Directory]::Exists($destResolved)) {
            [System.IO.Directory]::CreateDirectory($destResolved) | Out-Null
        }

        $inStream = [System.IO.File]::OpenRead($lastArchivePath)
        try {
            $buffer = [byte[]]::new($chunkSize)

            for ($n = 0; $n -lt $total; $n++) {
                $e       = $entries[$n]
                $sizeStr = Format-FctFileSize $e.FileSize

                Write-Progress -Id 1 `
                    -Activity        'Extracting FCT archive' `
                    -Status          "[$($n + 1) / $total] $($e.FormattedFilePath) ($sizeStr)" `
                    -PercentComplete ([int](($n / [Math]::Max($total, 1)) * 100))

                $sep       = [System.IO.Path]::DirectorySeparatorChar
                $nativeSub = $e.FormattedFilePath -replace '/', [string]$sep
                $outPath   = [System.IO.Path]::Combine($destResolved, $nativeSub)

                if (-not $PSCmdlet.ShouldProcess($outPath, 'Extract')) { continue }

                if ([System.IO.File]::Exists($outPath) -and -not $Force) {
                    $PSCmdlet.WriteError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.IO.IOException]::new(
                                "Output file '$outPath' already exists. Use -Force."
                            ),
                            'FctOutputExists',
                            [System.Management.Automation.ErrorCategory]::ResourceExists,
                            $outPath
                        )
                    )
                    continue
                }

                $outDir = [System.IO.Path]::GetDirectoryName($outPath)
                if ($outDir -and -not [System.IO.Directory]::Exists($outDir)) {
                    [System.IO.Directory]::CreateDirectory($outDir) | Out-Null
                }

                Write-Verbose "Extracting '$($e.FormattedFilePath)' ($($e.FileSize) bytes)."

                $extraChunk  = if ($e.LastChunkContentSize -ne 0) { 1 } else { 0 }
                $totalChunks = [int]$e.ChunkCount + $extraChunk
                $chunksDone  = 0
                $sw          = [System.Diagnostics.Stopwatch]::StartNew()

                $inStream.Seek([int64]$e.DataOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
                $outFile = [System.IO.File]::Open($outPath, [System.IO.FileMode]::Create)
                try {
                    for ($i = [uint64]0; $i -lt [uint64]$e.ChunkCount; $i++) {
                        $inStream.Read($buffer, 0, $chunkSize) | Out-Null
                        $outFile.Write($buffer, 0, $chunkSize)
                        $chunksDone++
                        if ($totalChunks -gt 0 -and $sw.ElapsedMilliseconds -ge 100) {
                            Write-Progress -Id 2 -ParentId 1 `
                                -Activity        $e.FormattedFilePath `
                                -Status          "Chunk $chunksDone / $totalChunks" `
                                -PercentComplete ([int]($chunksDone / $totalChunks * 100))
                            $sw.Restart()
                        }
                    }
                    if ($e.LastChunkContentSize -gt 0) {
                        $inStream.Read($buffer, 0, $chunkSize) | Out-Null
                        $outFile.Write($buffer, 0, [int]$e.LastChunkContentSize)
                    }
                }
                finally {
                    $outFile.Dispose()
                    Write-Progress -Id 2 -Activity $e.FormattedFilePath -Completed
                }
            }
        }
        finally {
            Write-Progress -Id 1 -Activity 'Extracting FCT archive' -Completed
            $inStream.Dispose()
        }
    }
}


function Remove-FctItem {
    <#
    .SYNOPSIS
        Removes one or more entries from an FCT archive.

    .DESCRIPTION
        Rewrites the archive atomically via a temporary file, omitting the
        specified entries. The original is replaced only after the temporary
        copy has been fully written and closed.

    .PARAMETER Path
        Path to the FCT archive.

    .PARAMETER Index
        One or more 1-based indices to remove. Automatically bound from
        Get-FctItem pipeline output.

    .EXAMPLE
        Remove-FctItem ./backup.fct -Index 3

    .EXAMPLE
        Remove-FctItem ./backup.fct -Index 1, 4

    .EXAMPLE
        Get-FctItem ./backup.fct | Where-Object EntryPath -like '*.log' |
            Remove-FctItem
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, Position = 0,
                   ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'LiteralPath', 'ArchivePath')]
        [string] $Path,

        [Parameter(Mandatory, Position = 1,
                   ValueFromPipelineByPropertyName)]
        [uint32[]] $Index
    )

    begin {
        $collectedIndices = [System.Collections.Generic.List[uint32]]::new()
        $resolvedPath     = $null
    }

    process {
        if (-not $resolvedPath) {
            $resolvedPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
        }
        foreach ($i in $Index) { $collectedIndices.Add([uint32]$i) }
    }

    end {
        if (-not $resolvedPath -or $collectedIndices.Count -eq 0) { return }

        $info      = Read-FctIndex -ArchivePath $resolvedPath
        $chunkSize = [int]$info.ChunkSize
        $entries   = $info.Entries
        $idxArr    = [uint32[]]$collectedIndices

        $toRemove = @($entries | Where-Object { $_.Index -in $idxArr })

        if ($toRemove.Count -eq 0) {
            Write-Warning "No entries matched the given indices in '$resolvedPath'."
            return
        }

        $desc = ($toRemove | ForEach-Object { "$($_.Index):$($_.FormattedFilePath)" }) -join ', '

        if (-not $PSCmdlet.ShouldProcess($resolvedPath, "Remove entries: $desc")) { return }

        $total     = $entries.Count
        $tmpPath   = $resolvedPath + '.tmp'
        $inStream  = [System.IO.File]::OpenRead($resolvedPath)
        $outStream = [System.IO.File]::Open(
            $tmpPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write
        )
        $writer = [System.IO.BinaryWriter]::new(
            $outStream, [System.Text.Encoding]::UTF8, $true
        )

        try {
            $archHdr = [byte[]]::new(5)
            $inStream.Read($archHdr, 0, 5) | Out-Null
            $writer.Write($archHdr)

            $buffer = [byte[]]::new($chunkSize)
            $n      = 0

            foreach ($e in $entries) {
                $n++
                $sizeStr = Format-FctFileSize $e.FileSize
                $action  = if ($e.Index -in $idxArr) { 'Removing' } else { 'Keeping' }

                Write-Progress -Id 1 `
                    -Activity        'Rewriting FCT archive' `
                    -Status          "[$n / $total] $action : $($e.FormattedFilePath) ($sizeStr)" `
                    -PercentComplete ([int](($n / [Math]::Max($total, 1)) * 100))

                if ($e.Index -in $idxArr) {
                    Write-Verbose "Removing '$($e.FormattedFilePath)'."
                    continue
                }

                $inStream.Seek([int64]$e.HeaderStart, [System.IO.SeekOrigin]::Begin) | Out-Null
                $hdrBuf = [byte[]]::new([int]$e.HeaderSize)
                $inStream.Read($hdrBuf, 0, [int]$e.HeaderSize) | Out-Null
                $writer.Write($hdrBuf)

                $extraChunk  = if ($e.LastChunkContentSize -ne 0) { [uint64]1 } else { [uint64]0 }
                $totalChunks = [uint64]$e.ChunkCount + $extraChunk

                for ($i = [uint64]0; $i -lt $totalChunks; $i++) {
                    $inStream.Read($buffer, 0, $chunkSize) | Out-Null
                    $writer.Write($buffer)
                }
            }
        }
        finally {
            Write-Progress -Id 1 -Activity 'Rewriting FCT archive' -Completed
            $writer.Dispose()
            $outStream.Dispose()
            $inStream.Dispose()
        }

        # atomic swap — only replaces the original after the temp is fully written
        [System.IO.File]::Delete($resolvedPath)
        [System.IO.File]::Move($tmpPath, $resolvedPath)

        Write-Verbose "Rewrote '$resolvedPath', removed $($toRemove.Count) entry/entries."
    }
}


Export-ModuleMember -Function New-FctArchive, Get-FctItem, Add-FctItem,
                               Expand-FctArchive, Remove-FctItem
