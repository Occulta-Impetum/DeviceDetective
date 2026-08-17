<#
.SYNOPSIS
    Device Detective alert evaluator for NinjaOne Script Result conditions.

.DESCRIPTION
    Reads Device Detective custom fields and emits exactly one concise evaluation
    line for NinjaOne to consume.

    Normal:
        DEVICE_DETECTIVE_NORMAL

    Non-normal or controlled helper error:
        DEVICE_DETECTIVE_ALERT | ...

    This script does not run Device Detective, modify custom fields, manage the
    baseline, contact Zendesk, or maintain persistent state.

.NOTES
    Uses NinjaOne's current Get-NinjaProperty cmdlet.

    Known Device Detective custom-field scripting names:
      Status          : deviceDetectiveStatus
      Current Devices : deviceDetectiveCurrentDevices
      Details         : deviceDetectiveDetails

    User context is read locally from Windows only when Device Detective is
    non-Normal. The script does not depend on NinjaOne's built-in Last Login
    inventory field.
#>

[CmdletBinding()]
param(
    # Optional test overrides. Leave unset in production.
    [string]$TestStatus,
    [string]$TestLastActiveUser,
    [string]$TestCurrentDevices,
    [string]$TestDetails
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

$CustomFields = @{
    Status         = "deviceDetectiveStatus"
    CurrentDevices = "deviceDetectiveCurrentDevices"
    Details        = "deviceDetectiveDetails"
}

# Keep the ticket output concise even if a multiline custom field grows large.
$MaximumOutputLength        = 6000
$MaximumDeviceSectionLength = 4000
$MaximumDetailsLength       = 1200

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------

function ConvertTo-CleanSingleLine {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value,

        [AllowEmptyString()]
        [string]$Fallback = ""
    )

    if ($null -eq $Value) {
        return $Fallback
    }

    $Text = if ($Value -is [System.Array]) {
        ([string[]]$Value -join " ")
    }
    else {
        [string]$Value
    }

    # NinjaOne may return multiline fields as separate array elements or as
    # normal CR/LF text depending on the command/version.
    $Text = $Text -replace "[`r`n`t]+", " "
    $Text = $Text -replace "\s{2,}", " "
    $Text = $Text.Trim()

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Fallback
    }

    return $Text
}

function Limit-Text {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value,

        [Parameter(Mandatory)]
        [int]$MaximumLength
    )

    if ([string]::IsNullOrEmpty($Value) -or $Value.Length -le $MaximumLength) {
        return $Value
    }

    $Suffix = " [truncated]"
    $KeepLength = [Math]::Max(0, $MaximumLength - $Suffix.Length)

    return $Value.Substring(0, $KeepLength).TrimEnd() + $Suffix
}

function Get-NinjaFieldValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [string]$Type
    )

    try {
        # Use NinjaOne's current PowerShell cmdlet. Supplying the field type lets
        # NinjaOne convert dropdown and multiline values into useful PowerShell
        # values instead of returning the legacy/raw representation.
        if ([string]::IsNullOrWhiteSpace($Type)) {
            $Value = Get-NinjaProperty -Name $Name -ErrorAction Stop
        }
        else {
            $Value = Get-NinjaProperty -Name $Name -Type $Type -ErrorAction Stop
        }

        if ($Value -is [System.Array]) {
            return ([string[]]$Value -join [Environment]::NewLine)
        }

        return $Value
    }
    catch {
        throw "Unable to read NinjaOne custom field '$Name': $($_.Exception.Message)"
    }
}

function Get-SecondaryFieldValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [string]$Type,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Fallback
    )

    try {
        return Get-NinjaFieldValue -Name $Name -Type $Type
    }
    catch {
        # Secondary-field failures must not prevent alert evaluation.
        return $Fallback
    }
}

function Get-LastActiveUser {
    [CmdletBinding()]
    param()

    # Prefer the user who is interactively logged on right now. This is queried
    # only for alert states so the Normal evaluation path remains lightweight.
    try {
        $ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $CurrentUser = ConvertTo-CleanSingleLine -Value $ComputerSystem.UserName -Fallback ""

        if (-not [string]::IsNullOrWhiteSpace($CurrentUser)) {
            return $CurrentUser
        }
    }
    catch {
        # Continue to the fallback below.
    }

    # If nobody is currently logged on, use Windows' locally recorded last
    # interactive logon identity. This is intentionally a fallback and is not
    # intended to duplicate NinjaOne's potentially delayed Last Login field.
    try {
        $LogonUiPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI"
        $LastUser = (Get-ItemProperty -LiteralPath $LogonUiPath -Name "LastLoggedOnUser" -ErrorAction Stop).LastLoggedOnUser
        $LastUser = ConvertTo-CleanSingleLine -Value $LastUser -Fallback ""

        if (-not [string]::IsNullOrWhiteSpace($LastUser)) {
            return $LastUser
        }
    }
    catch {
        # Controlled fallback below.
    }

    return "Not available"
}

function Get-DeviceBlocks {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$CurrentDevices
    )

    if ([string]::IsNullOrWhiteSpace($CurrentDevices)) {
        return @()
    }

    $Normalized = $CurrentDevices -replace "`r`n", "`n" -replace "`r", "`n"

    # Device Detective separates models with a blank line. Split on one or more
    # blank lines while tolerating whitespace on otherwise empty lines.
    return @(
        $Normalized -split "(?:`n\s*){2,}" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-BlockField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Block,

        [Parameter(Mandatory)]
        [string]$Label
    )

    $Pattern = "(?im)^\s*" + [regex]::Escape($Label) + "\s*:\s*(.*?)\s*$"
    $Match = [regex]::Match($Block, $Pattern)

    if ($Match.Success) {
        return $Match.Groups[1].Value.Trim()
    }

    return ""
}

function ConvertTo-DeviceSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Block
    )

    $Classification = Get-BlockField -Block $Block -Label "Classification"
    $VendorID       = Get-BlockField -Block $Block -Label "VendorID"
    $ProductID      = Get-BlockField -Block $Block -Label "ProductID"
    $VendorName     = Get-BlockField -Block $Block -Label "VendorName"
    $ProductName    = Get-BlockField -Block $Block -Label "ProductName"

    if ([string]::IsNullOrWhiteSpace($Classification)) {
        $Classification = "Unknown"
    }

    $DisplayName = if (-not [string]::IsNullOrWhiteSpace($ProductName) -and $ProductName -ne "Not found") {
        $ProductName
    }
    elseif (-not [string]::IsNullOrWhiteSpace($VendorName) -and $VendorName -ne "Not found") {
        $VendorName
    }
    else {
        "Unknown device"
    }

    $IdentifierParts = @()

    if (-not [string]::IsNullOrWhiteSpace($VendorID)) {
        $IdentifierParts += "VID $VendorID"
    }

    if (-not [string]::IsNullOrWhiteSpace($ProductID) -and $ProductID -ne "N/A") {
        $IdentifierParts += "PID $ProductID"
    }

    $IdentifierText = if ($IdentifierParts.Count -gt 0) {
        " (" + ($IdentifierParts -join ", ") + ")"
    }
    else {
        ""
    }

    return [PSCustomObject]@{
        Classification = $Classification
        Text           = "[$Classification] $DisplayName$IdentifierText"
        Priority       = switch ($Classification) {
            "Prohibited" { 0 }
            "Unknown"    { 1 }
            "Known"      { 2 }
            "Approved"   { 3 }
            "Ignored"    { 4 }
            default      { 2 }
        }
    }
}

function Format-ConnectedDevices {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$CurrentDevices
    )

    $Blocks = @(Get-DeviceBlocks -CurrentDevices $CurrentDevices)

    if ($Blocks.Count -eq 0) {
        return "No device data returned"
    }

    $Summaries = foreach ($Block in $Blocks) {
        ConvertTo-DeviceSummary -Block $Block
    }

    # Put the devices most useful for ticket review first so truncation retains
    # Prohibited/Unknown/Known entries before Approved devices.
    $Text = @(
        $Summaries |
        Sort-Object Priority, Text |
        Select-Object -ExpandProperty Text
    ) -join "; "

    return Limit-Text -Value $Text -MaximumLength $MaximumDeviceSectionLength
}

function Get-ConciseDetails {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Details
    )

    $Clean = ConvertTo-CleanSingleLine -Value $Details -Fallback ""

    if ([string]::IsNullOrWhiteSpace($Clean)) {
        return ""
    }

    return Limit-Text -Value $Clean -MaximumLength $MaximumDetailsLength
}

function Write-EvaluationResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $Clean = ConvertTo-CleanSingleLine -Value $Value -Fallback "DEVICE_DETECTIVE_ALERT | Status: Helper Script Error | Details: Unable to format evaluation output."
    $Clean = Limit-Text -Value $Clean -MaximumLength $MaximumOutputLength

    # Intentionally emit only this line to standard output.
    Write-Output $Clean
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    $UseTestStatus = $PSBoundParameters.ContainsKey("TestStatus")

    try {
        $RawStatus = if ($UseTestStatus) {
            $TestStatus
        }
        else {
            Get-NinjaFieldValue -Name $CustomFields.Status -Type "Dropdown"
        }
    }
    catch {
        $ErrorText = ConvertTo-CleanSingleLine -Value $_.Exception.Message -Fallback "Unable to read Device Detective status."
        $ErrorText = Limit-Text -Value $ErrorText -MaximumLength 800

        Write-EvaluationResult -Value "DEVICE_DETECTIVE_ALERT | Status: Helper Script Error | Details: $ErrorText"
        exit 0
    }

    $Status = ConvertTo-CleanSingleLine -Value $RawStatus -Fallback "Unknown"

    if ($Status -ceq "Normal") {
        Write-EvaluationResult -Value "DEVICE_DETECTIVE_NORMAL"
        exit 0
    }

    $LastActiveUser = if ($PSBoundParameters.ContainsKey("TestLastActiveUser")) {
        $TestLastActiveUser
    }
    else {
        Get-LastActiveUser
    }

    $CurrentDevices = if ($PSBoundParameters.ContainsKey("TestCurrentDevices")) {
        $TestCurrentDevices
    }
    else {
        Get-SecondaryFieldValue `
            -Name $CustomFields.CurrentDevices `
            -Type "Multiline" `
            -Fallback ""
    }

    $Details = if ($PSBoundParameters.ContainsKey("TestDetails")) {
        $TestDetails
    }
    else {
        Get-SecondaryFieldValue `
            -Name $CustomFields.Details `
            -Type "Multiline" `
            -Fallback ""
    }

    $LastActiveUser = ConvertTo-CleanSingleLine `
        -Value $LastActiveUser `
        -Fallback "Not available"

    $DeviceSummary = Format-ConnectedDevices -CurrentDevices ([string]$CurrentDevices)
    $ConciseDetails = Get-ConciseDetails -Details ([string]$Details)

    $Sections = @(
        "DEVICE_DETECTIVE_ALERT"
        "Status: $Status"
        "Last active user: $LastActiveUser"
        "Connected devices: $DeviceSummary"
    )

    if (-not [string]::IsNullOrWhiteSpace($ConciseDetails)) {
        $Sections += "Details: $ConciseDetails"
    }

    Write-EvaluationResult -Value ($Sections -join " | ")
    exit 0
}
catch {
    # Final controlled fallback. A helper failure should still produce the
    # marker NinjaOne evaluates whenever possible.
    try {
        $ErrorText = ConvertTo-CleanSingleLine -Value $_.Exception.Message -Fallback "Unexpected helper script failure."
        $ErrorText = Limit-Text -Value $ErrorText -MaximumLength 800

        Write-EvaluationResult -Value "DEVICE_DETECTIVE_ALERT | Status: Helper Script Error | Details: $ErrorText"
        exit 0
    }
    catch {
        # Catastrophic failure: no valid evaluation result could be produced.
        exit 1
    }
}
