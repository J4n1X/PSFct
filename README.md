# PSFct

PowerShell module for reading, writing, and managing FCT archives.

## Requirements

PowerShell 5.1 or later (Windows, Linux, macOS).

## Installation

```powershell
Import-Module .\PSFct\PSFct.psd1
```

## Cmdlets

| Cmdlet | Description |
|---|---|
| `New-FctArchive` | Create a new, empty FCT archive |
| `Get-FctItem` | List entries in an archive |
| `Add-FctItem` | Add files or directories to an archive |
| `Expand-FctArchive` | Extract files from an archive |
| `Remove-FctItem` | Remove entries from an archive |

## Quick Start

```powershell
# Create an archive with 4 KB chunks
New-FctArchive -Path backup.fct -ChunkSize 4096

# Add files
Add-FctItem -Path backup.fct -ItemPath C:\docs -RootDirectory C:\

# List contents
Get-FctItem -Path backup.fct

# Extract everything
Expand-FctArchive -Path backup.fct -DestinationPath C:\restore

# Extract specific files by index
Get-FctItem backup.fct -Filter "*.txt" | Expand-FctArchive -DestinationPath C:\restore

# Remove entries
Remove-FctItem -Path backup.fct -Index 2, 5
```
