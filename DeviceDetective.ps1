<#
.SYNOPSIS
    Device Detective for NinjaOne.

.DESCRIPTION
    This development version:
      - Reads the GitHub database URL from a NinjaOne script variable
      - Creates the local Device Detective working directory
      - Downloads, validates, caches, and hash-checks device-database.csv
      - Enumerates currently present Mouse, Keyboard, and HIDClass devices
      - Extracts and normalizes VID/PID values when available
      - Consolidates duplicate interfaces representing the same device model
      - Resolves friendly names and classifications from the local database
      - Refreshes the database once when an unresolved device is detected
      - Writes the current inventory and summary to NinjaOne custom fields

    Baseline comparison and alert-state persistence are not enabled yet.

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
    Action         = "deviceDetectiveAction"
    Baseline       = "deviceDetectiveBaseline"
    CurrentDevices = "deviceDetectiveCurrentDevices"
    DatabaseHash   = "deviceDetectiveDatabaseHash"
    Details        = "deviceDetectiveDetails"
    LastRun        = "deviceDetectiveLastRun"
    Status         = "deviceDetectiveStatus"
}

# Prevent excessively large values from being written to multiline fields.
$MaximumMultiLineLength = 9000

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

function Limit-MultiLineValue {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [Parameter(Mandatory)]
        [string]$Value
    )

    if ($Value.Length -le $MaximumMultiLineLength) {
        return $Value
    }

    $Suffix = "`r`n`r`n[Output truncated by Device Detective.]"
    return $Value.Substring(0, $MaximumMultiLineLength - $Suffix.Length) + $Suffix
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

function Import-DeviceDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $Rows = @(Import-Csv -LiteralPath $Path)

    foreach ($Row in $Rows) {
        if ($Row.VendorID -match '^[0-9A-Fa-f]{4}$') {
            $Row.VendorID = $Row.VendorID.ToUpperInvariant()
        }

        if ($Row.ProductID -match '^[0-9A-Fa-f]{4}$') {
            $Row.ProductID = $Row.ProductID.ToUpperInvariant()
        }
    }

    return $Rows
}

function Get-CurrentDeviceModels {
    [CmdletBinding()]
    param()

    Write-DeviceDetectiveLog "Collecting currently present Mouse, Keyboard, and HIDClass devices."

    try {
        $AllDevices = @(Get-PnpDevice -PresentOnly -Class Mouse, Keyboard, HIDClass -ErrorAction Stop)
    }
    catch {
        throw "Unable to enumerate Plug and Play devices: $($_.Exception.Message)"
    }

    $UniqueDevices = @{}

    foreach ($Device in $AllDevices) {
        $InstanceID = [string]$Device.InstanceId

        if ([string]::IsNullOrWhiteSpace($InstanceID)) {
            continue
        }

        $InstanceParts = $InstanceID -split '\\', 3
        $DeviceInformation = if ($InstanceParts.Count -ge 2) {
            $InstanceParts[1]
        }
        else {
            $InstanceID
        }

        $VendorID = $null
        $ProductID = $null
        $IsStandardVidPid = $false

        if ($InstanceID -match '(?i)VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') {
            $VendorID = $Matches[1].ToUpperInvariant()
            $ProductID = $Matches[2].ToUpperInvariant()
            $IsStandardVidPid = $true
        }
        else {
            # Preserve the behavior of the original script for devices that do
            # not expose normal USB VID/PID values, including some Bluetooth HID devices.
            $CandidateVendor = (($DeviceInformation -split '&')[0] -replace '(?i)^VID_', '').Trim()

            if (-not [string]::IsNullOrWhiteSpace($CandidateVendor)) {
                $VendorID = $CandidateVendor.ToUpperInvariant()
            }
        }

        # The original script excluded internal Intel HID records.
        if (-not [string]::IsNullOrWhiteSpace($VendorID) -and $VendorID.StartsWith('INTC')) {
            continue
        }

        $UniqueKey = if ($IsStandardVidPid) {
            "$VendorID|$ProductID"
        }
        else {
            "NONSTANDARD|$DeviceInformation"
        }

        if ($UniqueDevices.ContainsKey($UniqueKey)) {
            continue
        }

        $UniqueDevices[$UniqueKey] = [PSCustomObject]@{
            VendorID       = $VendorID
            VendorName     = ""
            ProductID      = $ProductID
            ProductName    = ""
            Classification = "Unknown"
            Notes           = ""
            FullDeviceData  = $DeviceInformation
            FriendlyName    = [string]$Device.FriendlyName
            PnpClass        = [string]$Device.Class
            InstanceID      = $InstanceID
            LookupMatched   = $false
        }
    }

    $Results = @($UniqueDevices.Values | Sort-Object VendorID, ProductID, FullDeviceData)
    Write-DeviceDetectiveLog "Collected $($Results.Count) unique monitored device models."
    return $Results
}

function Resolve-DeviceModels {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Devices,

        [Parameter(Mandatory)]
        [array]$Database
    )

    $ProductRows = @(
        $Database | Where-Object {
            $_.VendorID -match '^[0-9A-F]{4}$' -and
            $_.ProductID -match '^[0-9A-F]{4}$'
        }
    )

    $VendorRows = @(
        $Database | Where-Object {
            $_.VendorID -match '^[0-9A-F]{4}$' -and
            [string]::IsNullOrWhiteSpace($_.ProductID)
        }
    )

    foreach ($Device in $Devices) {
        if ($Device.VendorID -match '^[0-9A-F]{4}$' -and $Device.ProductID -match '^[0-9A-F]{4}$') {
            $MatchesForProduct = @(
                $ProductRows | Where-Object {
                    $_.VendorID -eq $Device.VendorID -and
                    $_.ProductID -eq $Device.ProductID
                }
            )

            if ($MatchesForProduct.Count -gt 0) {
                # Prefer a row with an explicit classification when duplicates exist.
                $Match = @($MatchesForProduct | Sort-Object {
                    if ([string]::IsNullOrWhiteSpace($_.Classification)) { 1 } else { 0 }
                })[0]

                $Device.VendorName = [string]$Match.VendorName
                $Device.ProductName = [string]$Match.ProductName
                $Device.Classification = if ([string]::IsNullOrWhiteSpace($Match.Classification)) {
                    "Known"
                }
                else {
                    [string]$Match.Classification
                }
                $Device.Notes = [string]$Match.Notes
                $Device.LookupMatched = $true
                continue
            }

            $VendorMatch = @($VendorRows | Where-Object { $_.VendorID -eq $Device.VendorID } | Select-Object -First 1)

            if ($VendorMatch.Count -gt 0) {
                $Device.VendorName = [string]$VendorMatch[0].VendorName
            }
            else {
                $Device.VendorName = "Not found"
            }

            $Device.ProductName = "Not found"
            $Device.Classification = "Unknown"
            continue
        }

        # Nonstandard identifiers cannot be matched safely to a VID/PID model.
        $Device.VendorName = "Not found"
        $Device.ProductName = if ([string]::IsNullOrWhiteSpace($Device.FriendlyName)) {
            "Not found"
        }
        else {
            $Device.FriendlyName
        }
        $Device.Classification = "Unknown"
    }

    return $Devices
}

function Format-CurrentDevices {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Devices
    )

    $Blocks = foreach ($Device in $Devices) {
        $VendorID = if ([string]::IsNullOrWhiteSpace([string]$Device.VendorID)) { "N/A" } else { $Device.VendorID }
        $ProductID = if ([string]::IsNullOrWhiteSpace([string]$Device.ProductID)) { "N/A" } else { $Device.ProductID }
        $VendorName = if ([string]::IsNullOrWhiteSpace([string]$Device.VendorName)) { "Not found" } else { $Device.VendorName }
        $ProductName = if ([string]::IsNullOrWhiteSpace([string]$Device.ProductName)) { "Not found" } else { $Device.ProductName }

        @(
            "Classification: $($Device.Classification)"
            "VendorID: $VendorID"
            "VendorName: $VendorName"
            "ProductID: $ProductID"
            "ProductName: $ProductName"
            "Device data: $($Device.FullDeviceData)"
        ) -join [Environment]::NewLine
    }

    return ($Blocks -join ([Environment]::NewLine + [Environment]::NewLine))
}

function Get-InventoryStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Devices
    )

    if (@($Devices | Where-Object { $_.Classification -eq "Prohibited" }).Count -gt 0) {
        return "Prohibited Device"
    }

    if (@($Devices | Where-Object { $_.Classification -in @("Known", "Unknown") }).Count -gt 0) {
        return "Review Required"
    }

    return "Normal"
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

    Write-DeviceDetectiveLog "Starting Device Detective development build."

    $Action = Get-DeviceDetectiveProperty -Name $CustomFields.Action -Type "Dropdown"

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
                Where-Object { $_.FullName -ne $LogPath } |
                Remove-Item -Force -ErrorAction Stop

            Set-DeviceDetectiveProperty -Name $CustomFields.Baseline -Value "" -Type "MultiLine"
            Set-DeviceDetectiveProperty -Name $CustomFields.CurrentDevices -Value "" -Type "MultiLine"
            $ForceDatabaseRefresh = $true
        }

        "Approve Current Baseline" {
            Write-DeviceDetectiveLog `
                -Level "WARNING" `
                -Message "Baseline approval is not implemented in this development version."
        }

        "None" {
            # No requested action.
        }

        default {
            Write-DeviceDetectiveLog -Level "WARNING" -Message "Unrecognized action value: $Action"
        }
    }

    $TrustedHash = Get-DeviceDetectiveProperty -Name $CustomFields.DatabaseHash -Type "Text"
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
        Set-DeviceDetectiveProperty -Name $CustomFields.DatabaseHash -Value $DatabaseResult.Hash -Type "Text"
    }
    else {
        $DatabaseResult = [PSCustomObject]@{
            Hash        = $LocalHash
            TotalRows   = $LocalValidation.TotalRows
            ProductRows = $LocalValidation.ProductRows
        }
    }

    $Database = @(Import-DeviceDatabase -Path $DatabasePath)
    $CurrentDevices = @(Get-CurrentDeviceModels)
    $CurrentDevices = @(Resolve-DeviceModels -Devices $CurrentDevices -Database $Database)

    $DatabaseRefreshedForUnknown = $false
    $UnresolvedBeforeRefresh = @($CurrentDevices | Where-Object { -not $_.LookupMatched })

    if ($UnresolvedBeforeRefresh.Count -gt 0 -and -not $DatabaseNeedsDownload) {
        Write-DeviceDetectiveLog `
            -Level "WARNING" `
            -Message "$($UnresolvedBeforeRefresh.Count) device(s) were unresolved. Refreshing the database once and retrying lookup."

        try {
            $DatabaseResult = Install-DeviceDatabase
            Set-DeviceDetectiveProperty -Name $CustomFields.DatabaseHash -Value $DatabaseResult.Hash -Type "Text"
            $DatabaseRefreshedForUnknown = $true
            $DatabaseNeedsDownload = $true

            $Database = @(Import-DeviceDatabase -Path $DatabasePath)
            $CurrentDevices = @(Resolve-DeviceModels -Devices $CurrentDevices -Database $Database)
        }
        catch {
            Write-DeviceDetectiveLog `
                -Level "WARNING" `
                -Message "Database refresh for unresolved devices failed. Continuing with the trusted local results. Error: $($_.Exception.Message)"
        }
    }

    $Status = Get-InventoryStatus -Devices $CurrentDevices
    $CurrentDeviceText = Limit-MultiLineValue -Value (Format-CurrentDevices -Devices $CurrentDevices)

    $ApprovedCount = @($CurrentDevices | Where-Object { $_.Classification -eq "Approved" }).Count
    $KnownCount = @($CurrentDevices | Where-Object { $_.Classification -eq "Known" }).Count
    $UnknownCount = @($CurrentDevices | Where-Object { $_.Classification -eq "Unknown" }).Count
    $ProhibitedCount = @($CurrentDevices | Where-Object { $_.Classification -eq "Prohibited" }).Count
    $IgnoredCount = @($CurrentDevices | Where-Object { $_.Classification -eq "Ignored" }).Count

    $ReviewDevices = @(
        $CurrentDevices | Where-Object { $_.Classification -in @("Known", "Unknown", "Prohibited") }
    )

    $ReviewSummary = if ($ReviewDevices.Count -eq 0) {
        "No devices currently require review."
    }
    else {
        @(
            "Devices requiring review:"
            $ReviewDevices | ForEach-Object {
                $VidPid = if ($_.ProductID) { "$($_.VendorID)/$($_.ProductID)" } else { [string]$_.VendorID }
                "- $($_.Classification): $VidPid - $($_.VendorName) / $($_.ProductName)"
            }
        ) -join [Environment]::NewLine
    }

    $Details = @(
        "Device Detective device inventory completed successfully."
        ""
        "Status: $Status"
        "Unique monitored device models: $($CurrentDevices.Count)"
        "Approved: $ApprovedCount"
        "Known: $KnownCount"
        "Unknown: $UnknownCount"
        "Prohibited: $ProhibitedCount"
        "Ignored: $IgnoredCount"
        ""
        $ReviewSummary
        ""
        "Database path: $DatabasePath"
        "Database hash: $($DatabaseResult.Hash)"
        "Database rows: $($DatabaseResult.TotalRows)"
        "Valid VID/PID product rows: $($DatabaseResult.ProductRows)"
        "Requested action: $Action"
        "GitHub contacted: $DatabaseNeedsDownload"
        "Database refreshed because of unresolved devices: $DatabaseRefreshedForUnknown"
        ""
        "Baseline comparison and alert-state persistence are not enabled in this version."
    ) -join [Environment]::NewLine

    Set-DeviceDetectiveProperty `
        -Name $CustomFields.CurrentDevices `
        -Value $CurrentDeviceText `
        -Type "MultiLine"

    Set-DeviceDetectiveProperty `
        -Name $CustomFields.Status `
        -Value $Status `
        -Type "Dropdown"

    Set-DeviceDetectiveProperty `
        -Name $CustomFields.Details `
        -Value (Limit-MultiLineValue -Value $Details) `
        -Type "MultiLine"

    Set-DeviceDetectiveProperty `
        -Name $CustomFields.LastRun `
        -Value $RunTime `
        -Type "DateTime"

    if ($Action -in @("Refresh Database", "Reset Local Data")) {
        Set-DeviceDetectiveProperty -Name $CustomFields.Action -Value "None" -Type "Dropdown"
    }

    Write-DeviceDetectiveLog "Device inventory completed successfully with status '$Status'."
    exit 0
}
catch {
    $ErrorMessage = $_.Exception.Message
    Write-DeviceDetectiveLog -Level "ERROR" -Message $ErrorMessage

    try {
        Set-DeviceDetectiveProperty -Name $CustomFields.Status -Value "Error" -Type "Dropdown"
        Set-DeviceDetectiveProperty `
            -Name $CustomFields.Details `
            -Value (Limit-MultiLineValue -Value "Device Detective failed.`n`n$ErrorMessage") `
            -Type "MultiLine"
        Set-DeviceDetectiveProperty -Name $CustomFields.LastRun -Value $RunTime -Type "DateTime"
    }
    catch {
        Write-Error "Unable to write the failure to NinjaOne custom fields: $($_.Exception.Message)"
    }

    exit 1
}
