<#
.SYNOPSIS
    Device Detective proof-of-concept for NinjaOne.

.DESCRIPTION
    This initial version:
      - Reads the GitHub database URL from a NinjaOne script variable
      - Creates the local Device Detective working directory
      - Downloads and validates device-database.csv
      - Uses an atomic replacement process
      - Calculates the database SHA-256 hash
      - Reads the Device Detective Action custom field
      - Writes test results to NinjaOne custom fields

    This version does not yet enumerate or compare connected devices.

.NINJAONE SCRIPT VARIABLE
    Name: GitHub URL
    Calculated name: githubUrl
    Type: String/Text
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

$DatabaseUrl = $env:githubUrl

$RootPath        = Join-Path $env:ProgramData "SysAdminBot\DeviceDetective"
$DatabasePath    = Join-Path $RootPath "device-database.csv"
$TemporaryPath   = Join-Path $RootPath "device-database.download"
$LogPath         = Join-Path $RootPath "DeviceDetective.log"

$RequiredColumns = @(
    "VendorID"
    "ProductID"
    "VendorName"
    "ProductName"
    "Classification"
    "Notes"
)

$ValidClassifications = @(
    "Approved"
    "Known"
    "Prohibited"
    "Ignored"
)

$CustomFields = @{
    Action       = "deviceDetectiveAction"
    DatabaseHash = "deviceDetectiveDatabaseHash"
    Details      = "deviceDetectiveDetails"
    LastRun      = "deviceDetectiveLastRun"
    Status       = "deviceDetectiveStatus"
}

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------

function Write-DeviceDetectiveLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"

    # Display in the NinjaOne activity output without adding data
    # to the PowerShell success pipeline.
    Write-Host $LogEntry

    try {
        Add-Content -Path $LogPath -Value $LogEntry -Encoding UTF8
    }
    catch {
        Write-Warning "Unable to write to the local log: $($_.Exception.Message)"
    }
}

function Get-DeviceDetectiveProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Type
    )

    try {
        return Get-NinjaProperty -Name $Name -Type $Type
    }
    catch {
        throw "Unable to read NinjaOne custom field '$Name': $($_.Exception.Message)"
    }
}

function Set-DeviceDetectiveProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowEmptyString()]
        [Parameter(Mandatory)]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Type
    )

    try {
        Set-NinjaProperty -Name $Name -Value $Value -Type $Type
    }
    catch {
        throw "Unable to update NinjaOne custom field '$Name': $($_.Exception.Message)"
    }
}

function Test-DeviceDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Database file does not exist: $Path"
    }

    $FileInfo = Get-Item -LiteralPath $Path

    if ($FileInfo.Length -eq 0) {
        throw "Database file is empty."
    }

    try {
        $Database = @(Import-Csv -LiteralPath $Path)
    }
    catch {
        throw "Database could not be imported as CSV: $($_.Exception.Message)"
    }

    if ($Database.Count -eq 0) {
        throw "Database contains no data rows."
    }

    $ActualColumns = @($Database[0].PSObject.Properties.Name)

    $MissingColumns = @(
        $RequiredColumns | Where-Object {
            $_ -notin $ActualColumns
        }
    )

    if ($MissingColumns.Count -gt 0) {
        throw "Database is missing required columns: $($MissingColumns -join ', ')"
    }

    $InvalidClassifications = @(
        $Database |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_.Classification) -and
                $_.Classification -notin $ValidClassifications
            } |
            Select-Object -ExpandProperty Classification -Unique
    )

    if ($InvalidClassifications.Count -gt 0) {
        throw "Database contains invalid classifications: $($InvalidClassifications -join ', ')"
    }

    $ProductRows = @(
        $Database | Where-Object {
            $_.VendorID -match '^[0-9A-Fa-f]{4}$' -and
            $_.ProductID -match '^[0-9A-Fa-f]{4}$'
        }
    )

    if ($ProductRows.Count -eq 0) {
        throw "Database contains no valid four-character VID/PID product records."
    }

    return [PSCustomObject]@{
        TotalRows   = $Database.Count
        ProductRows = $ProductRows.Count
    }
}

function Get-DatabaseHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Install-DeviceDatabase {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($DatabaseUrl)) {
        throw "The NinjaOne script variable 'GitHub URL' was not supplied."
    }

    if ($DatabaseUrl -notmatch '^https://') {
        throw "The GitHub URL must begin with https://."
    }

    Write-DeviceDetectiveLog "Downloading the device database."

    Remove-Item -LiteralPath $TemporaryPath -Force -ErrorAction SilentlyContinue

    try {
        Invoke-WebRequest `
            -Uri $DatabaseUrl `
            -OutFile $TemporaryPath `
            -UseBasicParsing `
            -TimeoutSec 30
    }
    catch {
        throw "Database download failed: $($_.Exception.Message)"
    }

    try {
        $ValidationResult = Test-DeviceDatabase -Path $TemporaryPath
        $DownloadedHash = Get-DatabaseHash -Path $TemporaryPath

        Move-Item `
            -LiteralPath $TemporaryPath `
            -Destination $DatabasePath `
            -Force
    }
    catch {
        Remove-Item -LiteralPath $TemporaryPath -Force -ErrorAction SilentlyContinue
        throw
    }

    Write-DeviceDetectiveLog "Database downloaded and validated successfully."

    return [PSCustomObject]@{
        Hash        = $DownloadedHash
        TotalRows   = $ValidationResult.TotalRows
        ProductRows = $ValidationResult.ProductRows
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$RunTime = Get-Date

try {
    # Ensure modern HTTPS support under Windows PowerShell 5.1.
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor `
        [Net.SecurityProtocolType]::Tls12

    if (-not (Test-Path -LiteralPath $RootPath)) {
        New-Item -Path $RootPath -ItemType Directory -Force | Out-Null
    }

    Write-DeviceDetectiveLog "Starting Device Detective proof-of-concept."

    $Action = Get-DeviceDetectiveProperty `
        -Name $CustomFields.Action `
        -Type "Dropdown"

    if ([string]::IsNullOrWhiteSpace([string]$Action)) {
        $Action = "None"
    }

    Write-DeviceDetectiveLog "Requested action: $Action"

    $ForceDatabaseRefresh = $false

    switch ($Action) {
        "Refresh Database" {
            $ForceDatabaseRefresh = $true
            Write-DeviceDetectiveLog "A database refresh was requested."
        }

        "Reset Local Data" {
            Write-DeviceDetectiveLog "A local-data reset was requested."

            Get-ChildItem -LiteralPath $RootPath -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.FullName -ne $LogPath
                } |
                Remove-Item -Force -ErrorAction Stop

            $ForceDatabaseRefresh = $true
        }

        "Approve Current Baseline" {
            Write-DeviceDetectiveLog `
                -Level "WARNING" `
                -Message "Baseline approval is not implemented in this proof-of-concept."
        }

        "None" {
            # No requested action.
        }

        default {
            Write-DeviceDetectiveLog `
                -Level "WARNING" `
                -Message "Unrecognized action value: $Action"
        }
    }

    $TrustedHash = Get-DeviceDetectiveProperty `
        -Name $CustomFields.DatabaseHash `
        -Type "Text"

    $DatabaseNeedsDownload = $ForceDatabaseRefresh

    if (-not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)) {
        Write-DeviceDetectiveLog "No local database exists."
        $DatabaseNeedsDownload = $true
    }
    elseif ([string]::IsNullOrWhiteSpace([string]$TrustedHash)) {
        Write-DeviceDetectiveLog `
            -Level "WARNING" `
            -Message "The trusted database hash is empty. The official database will be downloaded."

        $DatabaseNeedsDownload = $true
    }
    else {
        try {
            $LocalValidation = Test-DeviceDatabase -Path $DatabasePath
            $LocalHash = Get-DatabaseHash -Path $DatabasePath

            if ($LocalHash -ne ([string]$TrustedHash).Trim().ToUpperInvariant()) {
                Write-DeviceDetectiveLog `
                    -Level "WARNING" `
                    -Message "The local database hash does not match the trusted NinjaOne hash."

                $DatabaseNeedsDownload = $true
            }
            else {
                Write-DeviceDetectiveLog "The local database is valid and trusted."
            }
        }
        catch {
            Write-DeviceDetectiveLog `
                -Level "WARNING" `
                -Message "Local database validation failed: $($_.Exception.Message)"

            $DatabaseNeedsDownload = $true
        }
    }

    if ($DatabaseNeedsDownload) {
        $DatabaseResult = Install-DeviceDatabase

        Set-DeviceDetectiveProperty `
            -Name $CustomFields.DatabaseHash `
            -Value $DatabaseResult.Hash `
            -Type "Text"
    }
    else {
        $DatabaseResult = [PSCustomObject]@{
            Hash        = $LocalHash
            TotalRows   = $LocalValidation.TotalRows
            ProductRows = $LocalValidation.ProductRows
        }
    }

    $Details = @(
        "Device Detective proof-of-concept completed successfully."
        ""
        "Database path: $DatabasePath"
        "Database hash: $($DatabaseResult.Hash)"
        "Database rows: $($DatabaseResult.TotalRows)"
        "Valid VID/PID product rows: $($DatabaseResult.ProductRows)"
        "Requested action: $Action"
        "GitHub contacted: $DatabaseNeedsDownload"
        ""
        "Device detection and baseline comparison are not enabled in this version."
    ) -join [Environment]::NewLine

    Set-DeviceDetectiveProperty `
        -Name $CustomFields.Status `
        -Value "Normal" `
        -Type "Dropdown"

    Set-DeviceDetectiveProperty `
        -Name $CustomFields.Details `
        -Value $Details `
        -Type "MultiLine"

    Set-DeviceDetectiveProperty `
        -Name $CustomFields.LastRun `
        -Value $RunTime `
        -Type "DateTime"

    if ($Action -in @("Refresh Database", "Reset Local Data")) {
        Set-DeviceDetectiveProperty `
            -Name $CustomFields.Action `
            -Value "None" `
            -Type "Dropdown"
    }

    Write-DeviceDetectiveLog "Proof-of-concept completed successfully."
    exit 0
}
catch {
    $ErrorMessage = $_.Exception.Message

    Write-DeviceDetectiveLog `
        -Level "ERROR" `
        -Message $ErrorMessage

    try {
        Set-DeviceDetectiveProperty `
            -Name $CustomFields.Status `
            -Value "Error" `
            -Type "Dropdown"

        Set-DeviceDetectiveProperty `
            -Name $CustomFields.Details `
            -Value "Device Detective proof-of-concept failed.`n`n$ErrorMessage" `
            -Type "MultiLine"

        Set-DeviceDetectiveProperty `
            -Name $CustomFields.LastRun `
            -Value $RunTime `
            -Type "DateTime"
    }
    catch {
        Write-Error "Unable to write the failure to NinjaOne custom fields: $($_.Exception.Message)"
    }

    exit 1
}