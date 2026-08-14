<#
.SYNOPSIS
    Device Detective for NinjaOne.

.DESCRIPTION
    This development version:
      - Reads the GitHub database URL from a NinjaOne script variable
      - Creates the local Device Detective working directory
      - Downloads, validates, caches, and hash-checks device-database.csv
      - Enumerates currently present Mouse, Keyboard, and HIDClass devices
      - Extracts and normalizes USB and Bluetooth VID/PID values when available
      - Consolidates duplicate interfaces representing the same physical device model
      - Excludes generic Bluetooth HID child interfaces that cannot identify a model
      - Excludes built-in Microsoft Surface HID/touch interfaces from monitored inventory
      - Resolves friendly names and classifications from the local database
      - Refreshes the database only for valid VID/PID models missing from the cache
      - Writes the current inventory and summary to NinjaOne custom fields
      - Creates and maintains an accepted device baseline
      - Automatically accepts states containing only Approved or Ignored models
      - Supports manual baseline approval through a NinjaOne action field
      - Rejects manual baseline approval when a Prohibited model is present
      - Reports added, removed, and reclassified models in the details field

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

$RootPath      = Join-Path $env:ProgramData "SysAdminBot\DeviceDetective"
$DatabasePath  = Join-Path $RootPath "device-database.csv"
$TemporaryPath = Join-Path $RootPath "device-database.download"
$LogPath       = Join-Path $RootPath "DeviceDetective.log"

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

# Prevent repeated GitHub downloads when a valid but unknown model remains connected.
$MinimumMissingModelRefreshAgeHours = 24

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
        $PropertyValue = Get-NinjaProperty -Name $Name -Type $Type

        # NinjaOne returns MultiLine custom fields as an Object[] containing
        # one element per line. Reassemble those elements into the original
        # text before returning the value to the rest of the script.
        if ($Type -eq "MultiLine" -and $PropertyValue -is [System.Array]) {
            return ([string[]]$PropertyValue -join [Environment]::NewLine)
        }

        return $PropertyValue
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
    $MissingColumns = @($RequiredColumns | Where-Object { $_ -notin $ActualColumns })

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


function Invoke-DeviceDetectiveWinRTAwait {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Operation,

        [Parameter(Mandatory)]
        [Type]$ResultType
    )

    $AsTaskGeneric = (
        [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq 'AsTask' -and
            $_.IsGenericMethodDefinition -and
            $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        }
    )[0]

    if ($null -eq $AsTaskGeneric) {
        throw "Unable to locate the WinRT AsTask helper method."
    }

    $AsTask = $AsTaskGeneric.MakeGenericMethod($ResultType)
    $Task = $AsTask.Invoke($null, @($Operation))
    $Task.Wait()

    return $Task.Result
}

function Get-BluetoothLEMetadata {
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop

    $null = [Windows.Devices.Bluetooth.BluetoothLEDevice,Windows.Devices.Bluetooth,ContentType=WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformation,Windows.Devices.Enumeration,ContentType=WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformationCollection,Windows.Devices.Enumeration,ContentType=WindowsRuntime]

    $RequestedProperties = [string[]]@(
        'System.Devices.Aep.DeviceAddress',
        'System.Devices.Aep.IsConnected',
        'System.Devices.Aep.IsPaired'
    )

    # This selector returns Bluetooth LE association endpoints that Windows knows
    # about, including paired devices that may currently be asleep/disconnected.
    $Selector = [Windows.Devices.Bluetooth.BluetoothLEDevice]::GetDeviceSelector()

    $DeviceInformationCollection = Invoke-DeviceDetectiveWinRTAwait `
        -Operation ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
            $Selector,
            $RequestedProperties
        )) `
        -ResultType ([Windows.Devices.Enumeration.DeviceInformationCollection])
    # Collect the top-level BTHLE devices once, then correlate by Bluetooth address.
    # Property {104EA319-6EE2-4701-BD47-8DDBF425BBE5} 7 was validated on BLE HID
    # devices to update when an asleep/disconnected device wakes and reconnects.
    # It is supplemental telemetry only and does not affect inventory/baseline state.
    $BluetoothPnpDevices = @()

    try {
        $BluetoothPnpDevices = @(
            Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object {
                [string]$_.InstanceId -match '(?i)^BTHLE\\DEV_[0-9A-F]{12}'
            }
        )
    }
    catch {
        Write-DeviceDetectiveLog "Unable to enumerate top-level Bluetooth LE Plug and Play devices for wake/connect timestamps: $($_.Exception.Message)" -Level "WARNING"
    }

    $Results = @{}

    foreach ($DeviceInformation in $DeviceInformationCollection) {
        $PropertyTable = @{}

        # Windows PowerShell 5.1 projects the WinRT IReadOnlyDictionary as
        # KeyValuePair objects, so copy the collection into a normal hashtable.
        foreach ($Property in $DeviceInformation.Properties) {
            $PropertyTable[[string]$Property.Key] = $Property.Value
        }

        $Address = [string]$PropertyTable['System.Devices.Aep.DeviceAddress']

        # Fall back to the address embedded in DeviceInformation.Id when the
        # requested AEP property is unavailable.
        if ([string]::IsNullOrWhiteSpace($Address)) {
            if ([string]$DeviceInformation.Id -match '(?i)-([0-9A-F]{2}(?::[0-9A-F]{2}){5})$') {
                $Address = $Matches[1]
            }
        }

        $NormalizedAddress = ($Address -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()

        if ($NormalizedAddress -notmatch '^[0-9A-F]{12}$') {
            continue
        }

        $LastWakeConnect = $null
        $MatchingPnpDevice = @(
            $BluetoothPnpDevices |
            Where-Object {
                [string]$_.InstanceId -match ("(?i)^BTHLE\\DEV_{0}(?:\\|$)" -f [regex]::Escape($NormalizedAddress))
            } |
            Select-Object -First 1
        )

        if ($MatchingPnpDevice.Count -gt 0) {
            try {
                $LastWakeConnectProperty = Get-PnpDeviceProperty `
                    -InstanceId $MatchingPnpDevice[0].InstanceId `
                    -KeyName '{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 7' `
                    -ErrorAction Stop

                if ($null -ne $LastWakeConnectProperty -and $null -ne $LastWakeConnectProperty.Data) {
                    $LastWakeConnect = $LastWakeConnectProperty.Data
                }
            }
            catch {
                # Wake/connect time is supplemental telemetry. Do not fail
                # inventory collection if a particular device lacks the property.
            }
        }

        $IsConnected = $null
        if ($PropertyTable.ContainsKey('System.Devices.Aep.IsConnected')) {
            $IsConnected = [bool]$PropertyTable['System.Devices.Aep.IsConnected']
        }

        $IsPaired = $null
        if ($PropertyTable.ContainsKey('System.Devices.Aep.IsPaired')) {
            $IsPaired = [bool]$PropertyTable['System.Devices.Aep.IsPaired']
        }

        $Results[$NormalizedAddress] = [PSCustomObject]@{
            Name          = [string]$DeviceInformation.Name
            Address       = $NormalizedAddress
            IsConnected   = $IsConnected
            IsPaired      = $IsPaired
            LastWakeConnect = $LastWakeConnect
            DeviceId      = [string]$DeviceInformation.Id
        }
    }

    return $Results
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
    $IgnoredGenericBluetoothInterfaces = 0
    $IgnoredBuiltInSurfaceInterfaces = 0
    $IgnoredConvertedDeviceInterfaces = 0
    $IgnoredVhfChildInterfaces = 0
    $BluetoothInterfacesWithoutAddress = 0
    $BluetoothMetadataMatches = 0

    $BluetoothLEMetadata = @{}

    $HasBluetoothLEHidRecords = @(
        $AllDevices |
        Where-Object {
            [string]$_.InstanceId -match '(?i)^BTHLEDEVICE\\'
        }
    ).Count -gt 0

    if ($HasBluetoothLEHidRecords) {
        try {
            $BluetoothLEMetadata = Get-BluetoothLEMetadata
            Write-DeviceDetectiveLog "Retrieved supplemental metadata for $($BluetoothLEMetadata.Count) Bluetooth LE device(s)."
        }
        catch {
            Write-DeviceDetectiveLog "Unable to retrieve supplemental Bluetooth LE metadata. Bluetooth inventory will continue without it: $($_.Exception.Message)" -Level "WARNING"
            $BluetoothLEMetadata = @{}
        }
    }

    # Build a set of physical/model VID/PID identities already represented in
    # the monitored PnP inventory. This is used only to validate VHF children:
    # a VHF record is ignored only when its parent resolves to a VID/PID model
    # that is also independently present in the Mouse/Keyboard/HIDClass scan.
    $DetectedVidPidKeys = @{}

    foreach ($DetectedDevice in $AllDevices) {
        $DetectedInstanceId = [string]$DetectedDevice.InstanceId

        if ($DetectedInstanceId -match '(?i)VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') {
            $DetectedKey = "$($Matches[1].ToUpperInvariant())|$($Matches[2].ToUpperInvariant())"
            $DetectedVidPidKeys[$DetectedKey] = $true
        }
        elseif ($DetectedInstanceId -match '(?i)_DEV_VID&[0-9A-F]{2}([0-9A-F]{4})_PID&([0-9A-F]{4})') {
            $DetectedKey = "$($Matches[1].ToUpperInvariant())|$($Matches[2].ToUpperInvariant())"
            $DetectedVidPidKeys[$DetectedKey] = $true
        }
        elseif ($DetectedInstanceId -match '(?i)_VID&[0-9A-F]{4}([0-9A-F]{4})_PID&([0-9A-F]{4})') {
            $DetectedKey = "$($Matches[1].ToUpperInvariant())|$($Matches[2].ToUpperInvariant())"
            $DetectedVidPidKeys[$DetectedKey] = $true
        }
    }

    # Surface systems expose many built-in touch, pen, button, keyboard, and
    # Virtual HID Framework interfaces through HIDClass. These are internal
    # platform devices rather than removable peripherals that Device Detective
    # is intended to monitor. Limit the filter to confirmed Microsoft Surface
    # hardware so similarly named interfaces on other computers remain visible.
    $IsMicrosoftSurface = $false

    try {
        $ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $IsMicrosoftSurface = (
            [string]$ComputerSystem.Manufacturer -match '(?i)^Microsoft' -and
            [string]$ComputerSystem.Model -match '(?i)^Surface'
        )
    }
    catch {
        Write-DeviceDetectiveLog "Unable to determine whether this computer is a Microsoft Surface. Surface-specific filtering will not be applied: $($_.Exception.Message)" -Level "WARNING"
    }

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
        $IdentifierType = "Nonstandard"
        $BluetoothAddress = $null

        # Standard USB/HID format, for example VID_03F0&PID_584A.
        if ($InstanceID -match '(?i)VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') {
            $VendorID = $Matches[1].ToUpperInvariant()
            $ProductID = $Matches[2].ToUpperInvariant()
            $IdentifierType = "Standard VID/PID"
        }
        # Bluetooth LE GATT HID records can encode a two-character vendor-ID
        # source immediately before the actual four-character vendor ID.
        # Examples observed in Windows:
        # {GUID}_DEV_VID&02046D_PID&B02B -> VID 046D / PID B02B
        # {GUID}_DEV_VID&02046D_PID&B383 -> VID 046D / PID B383
        # Capture the final four characters as the vendor ID and discard the
        # two-character source value.
        elseif ($DeviceInformation -match '(?i)_DEV_VID&[0-9A-F]{2}([0-9A-F]{4})_PID&([0-9A-F]{4})') {
            $VendorID = $Matches[1].ToUpperInvariant()
            $ProductID = $Matches[2].ToUpperInvariant()
            $IdentifierType = "Bluetooth LE VID/PID"

            # The BTHLEDEVICE instance ID also contains the 12-character
            # Bluetooth address immediately before the final instance path.
            # Example:
            # ..._DEV_VID&02046D_PID&B02B_REV&0014_D2E01ED79E81\...
            # HID child collections may append &COLxx after the Bluetooth
            # address before the instance-path separator, for example:
            # ..._C8678A54D1D6&COL01\...
            # Try both the full InstanceId and the normalized device data so
            # either Windows representation can supply the address.
            $BluetoothAddressSource = @(
                [string]$InstanceID,
                [string]$DeviceInformation
            )

            foreach ($AddressSource in $BluetoothAddressSource) {
                if (
                    -not [string]::IsNullOrWhiteSpace($AddressSource) -and
                    $AddressSource -match '(?i)_([0-9A-F]{12})(?:&COL[0-9A-F]+)?(?:\\|$)'
                ) {
                    $BluetoothAddress = $Matches[1].ToUpperInvariant()
                    break
                }
            }
        }
        # Bluetooth Classic HID can encode the vendor source plus the actual
        # four-character vendor ID, for example:
        # {GUID}_VID&00023434_PID&02A0 -> VID 3434 / PID 02A0.
        elseif ($DeviceInformation -match '(?i)_VID&[0-9A-F]{4}([0-9A-F]{4})_PID&([0-9A-F]{4})') {
            $VendorID = $Matches[1].ToUpperInvariant()
            $ProductID = $Matches[2].ToUpperInvariant()
            $IdentifierType = "Bluetooth VID/PID"
        }
        else {
            $CandidateVendor = (($DeviceInformation -split '&')[0] -replace '(?i)^VID_', '').Trim()

            if (-not [string]::IsNullOrWhiteSpace($CandidateVendor)) {
                $VendorID = $CandidateVendor.ToUpperInvariant()
            }
        }

        # The original script excluded internal Intel HID records.
        if (-not [string]::IsNullOrWhiteSpace($VendorID) -and $VendorID.StartsWith('INTC')) {
            continue
        }

        $HasValidVidPid = (
            $VendorID -match '^[0-9A-F]{4}$' -and
            $ProductID -match '^[0-9A-F]{4}$'
        )

        # Bluetooth connection state is supplemental telemetry only. Battery-
        # powered HID devices can sleep while still being legitimate peripherals,
        # so Connected/Disconnected must never add/remove a device or alter the
        # baseline. Correlate metadata by Bluetooth address when available.
        $BluetoothMetadataRecord = $null

        if ($IdentifierType -eq "Bluetooth LE VID/PID" -and $HasValidVidPid) {
            if ([string]::IsNullOrWhiteSpace($BluetoothAddress)) {
                $BluetoothInterfacesWithoutAddress++
            }
            elseif ($BluetoothLEMetadata.ContainsKey($BluetoothAddress)) {
                $BluetoothMetadataRecord = $BluetoothLEMetadata[$BluetoothAddress]
                $BluetoothMetadataMatches++
            }
        }

        # Microsoft Surface systems expose internal HID interfaces for touch,
        # pen, buttons, the built-in keyboard/touchpad, and Virtual HID Framework.
        # They frequently use nonstandard identifiers instead of USB VID/PID.
        # Ignore only these known internal patterns and only on confirmed Surface
        # hardware. Valid VID/PID devices are never removed by this filter.
        $FriendlyName = [string]$Device.FriendlyName
        $IsBuiltInSurfaceInterface = (
            $IsMicrosoftSurface -and
            -not $HasValidVidPid -and
            (
                $FriendlyName -match '(?i)^Surface\b' -or
                $FriendlyName -match '(?i)^Intel\(R\) Precise Touch and Stylus\b' -or
                $DeviceInformation -match '(?i)^CONVERTEDDEVICE(?:&COL[0-9A-F]+)?$' -or
                $DeviceInformation -match '(?i)^HID_DEVICE_SYSTEM_VHF(?:&COL[0-9A-F]+)?$' -or
                $DeviceInformation -match '(?i)^TARGET_(?:SAM|KIP)&CATEGORY_HID(?:&COL[0-9A-F]+)?$' -or
                $DeviceInformation -match '(?i)^MSHW0005$'
            )
        )

        if ($IsBuiltInSurfaceInterface) {
            $IgnoredBuiltInSurfaceInterfaces++
            continue
        }

        # Virtual HID Framework (VHF) can expose a nonstandard child record such
        # as HID_DEVICE_SYSTEM_VHF for a real physical peripheral. Do not ignore
        # VHF globally. Ignore it only when Windows reports a parent with a valid
        # VID/PID and that same VID/PID model is independently present in the
        # monitored PnP inventory. This was observed with the Logitech G213:
        # VHF\HID_DEVICE_SYSTEM_VHF -> parent USB\VID_046D&PID_C336 -> G213.
        $IsValidatedVhfChild = $false

        if (
            -not $HasValidVidPid -and
            $DeviceInformation -match '(?i)^HID_DEVICE_SYSTEM_VHF(?:&COL[0-9A-F]+)?$'
        ) {
            try {
                $ParentProperty = Get-PnpDeviceProperty `
                    -InstanceId $InstanceID `
                    -KeyName 'DEVPKEY_Device_Parent' `
                    -ErrorAction Stop

                $ParentInstanceId = [string]$ParentProperty.Data

                if (
                    -not [string]::IsNullOrWhiteSpace($ParentInstanceId) -and
                    $ParentInstanceId -match '(?i)VID_([0-9A-F]{4})&PID_([0-9A-F]{4})'
                ) {
                    $ParentVendorId = $Matches[1].ToUpperInvariant()
                    $ParentProductId = $Matches[2].ToUpperInvariant()
                    $ParentVidPidKey = "$ParentVendorId|$ParentProductId"

                    if ($DetectedVidPidKeys.ContainsKey($ParentVidPidKey)) {
                        $IsValidatedVhfChild = $true
                    }
                }
            }
            catch {
                # If the parent cannot be resolved, retain the VHF record for
                # review rather than risk hiding an unexplained virtual HID.
            }
        }

        if ($IsValidatedVhfChild) {
            $IgnoredVhfChildInterfaces++
            continue
        }

        # Windows can expose internal ACPI/firmware HID collections using the
        # nonstandard CONVERTEDDEVICE identifier. These interfaces represent
        # built-in system controls rather than a removable USB/Bluetooth model.
        # Ignore only the base CONVERTEDDEVICE record and its numbered
        # collection children, and never suppress a device with a valid VID/PID.
        $IsConvertedDeviceInterface = (
            -not $HasValidVidPid -and
            $DeviceInformation -match '(?i)^CONVERTEDDEVICE(?:&COL[0-9A-F]+)?$'
        )

        if ($IsConvertedDeviceInterface) {
            $IgnoredConvertedDeviceInterfaces++
            continue
        }

        # Windows exposes generic BLE GATT child interfaces in addition to the
        # actual keyboard or mouse model. These records do not safely identify
        # a model and should not create a duplicate Unknown device.
        $IsGenericBluetoothChild = (
            -not $HasValidVidPid -and
            (
                [string]$Device.FriendlyName -match '(?i)^Bluetooth Low Energy GATT compliant HID device$' -or
                [string]$Device.FriendlyName -match '(?i)^Bluetooth HID Device$'
            )
        )

        if ($IsGenericBluetoothChild) {
            $IgnoredGenericBluetoothInterfaces++
            continue
        }

        # Normalized VID/PID is the model identity. USB and Bluetooth interfaces
        # for the same model therefore collapse into one inventory entry.
        $UniqueKey = if ($HasValidVidPid) {
            "$VendorID|$ProductID"
        }
        else {
            "NONSTANDARD|$DeviceInformation"
        }

        if ($UniqueDevices.ContainsKey($UniqueKey)) {
            $ExistingDevice = $UniqueDevices[$UniqueKey]

            if ($null -ne $BluetoothMetadataRecord) {
                $ExistingDevice.BluetoothName = [string]$BluetoothMetadataRecord.Name
                $ExistingDevice.BluetoothAddress = [string]$BluetoothMetadataRecord.Address
                $ExistingDevice.BluetoothConnected = $BluetoothMetadataRecord.IsConnected
                $ExistingDevice.BluetoothPaired = $BluetoothMetadataRecord.IsPaired
                $ExistingDevice.BluetoothLastWakeConnect = $BluetoothMetadataRecord.LastWakeConnect
            }

            continue
        }

        $UniqueDevices[$UniqueKey] = [PSCustomObject]@{
            VendorID               = $VendorID
            VendorName             = ""
            ProductID              = $ProductID
            ProductName            = ""
            Classification         = "Unknown"
            Notes                  = ""
            FullDeviceData         = $DeviceInformation
            FriendlyName           = [string]$Device.FriendlyName
            PnpClass               = [string]$Device.Class
            InstanceID             = $InstanceID
            IdentifierType         = $IdentifierType
            HasValidVidPid         = $HasValidVidPid
            LookupMatched          = $false
            BluetoothName          = if ($null -ne $BluetoothMetadataRecord) { [string]$BluetoothMetadataRecord.Name } else { "" }
            BluetoothAddress       = if ($null -ne $BluetoothMetadataRecord) { [string]$BluetoothMetadataRecord.Address } else { $BluetoothAddress }
            BluetoothConnected     = if ($null -ne $BluetoothMetadataRecord) { $BluetoothMetadataRecord.IsConnected } else { $null }
            BluetoothPaired        = if ($null -ne $BluetoothMetadataRecord) { $BluetoothMetadataRecord.IsPaired } else { $null }
            BluetoothLastWakeConnect = if ($null -ne $BluetoothMetadataRecord) { $BluetoothMetadataRecord.LastWakeConnect } else { $null }
        }
    }

    $Results = @($UniqueDevices.Values | Sort-Object VendorID, ProductID, FullDeviceData)
    Write-DeviceDetectiveLog "Collected $($Results.Count) unique monitored device models."

    if ($IgnoredGenericBluetoothInterfaces -gt 0) {
        Write-DeviceDetectiveLog "Ignored $IgnoredGenericBluetoothInterfaces generic Bluetooth HID child interface(s)."
    }

    if ($IgnoredBuiltInSurfaceInterfaces -gt 0) {
        Write-DeviceDetectiveLog "Ignored $IgnoredBuiltInSurfaceInterfaces built-in Microsoft Surface HID interface(s)."
    }

    if ($IgnoredConvertedDeviceInterfaces -gt 0) {
        Write-DeviceDetectiveLog "Ignored $IgnoredConvertedDeviceInterfaces internal CONVERTEDDEVICE HID interface(s)."
    }

    if ($IgnoredVhfChildInterfaces -gt 0) {
        Write-DeviceDetectiveLog "Ignored $IgnoredVhfChildInterfaces VHF HID child interface(s) whose parent VID/PID model is already represented in the monitored inventory."
    }

    if ($BluetoothMetadataMatches -gt 0) {
        Write-DeviceDetectiveLog "Matched supplemental Bluetooth metadata to $BluetoothMetadataMatches Bluetooth LE HID interface(s)."
    }

    if ($BluetoothInterfacesWithoutAddress -gt 0) {
        Write-DeviceDetectiveLog "Unable to extract a Bluetooth address from $BluetoothInterfacesWithoutAddress Bluetooth LE HID interface(s); inventory was retained without supplemental Bluetooth metadata." -Level "WARNING"
    }

    return $Results
}

function Resolve-DeviceModels {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
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
        [AllowEmptyCollection()]
        [array]$Devices
    )

    $Blocks = foreach ($Device in $Devices) {
        $VendorID = if ([string]::IsNullOrWhiteSpace([string]$Device.VendorID)) { "N/A" } else { $Device.VendorID }
        $ProductID = if ([string]::IsNullOrWhiteSpace([string]$Device.ProductID)) { "N/A" } else { $Device.ProductID }
        $VendorName = if ([string]::IsNullOrWhiteSpace([string]$Device.VendorName)) { "Not found" } else { $Device.VendorName }
        $ProductName = if ([string]::IsNullOrWhiteSpace([string]$Device.ProductName)) { "Not found" } else { $Device.ProductName }

        $Lines = @(
            "Classification: $($Device.Classification)"
            "VendorID: $VendorID"
            "VendorName: $VendorName"
            "ProductID: $ProductID"
            "ProductName: $ProductName"
            "Identifier type: $($Device.IdentifierType)"
            "Device data: $($Device.FullDeviceData)"
        )

        if (
            $Device.IdentifierType -eq "Bluetooth LE VID/PID" -or
            -not [string]::IsNullOrWhiteSpace([string]$Device.BluetoothAddress)
        ) {
            if (-not [string]::IsNullOrWhiteSpace([string]$Device.BluetoothName)) {
                $Lines += "Bluetooth name: $($Device.BluetoothName)"
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$Device.BluetoothAddress)) {
                $Lines += "Bluetooth address: $($Device.BluetoothAddress)"
            }

            $BluetoothConnectedText = if ($null -eq $Device.BluetoothConnected) {
                "Unknown"
            }
            else {
                [string][bool]$Device.BluetoothConnected
            }

            $BluetoothPairedText = if ($null -eq $Device.BluetoothPaired) {
                "Unknown"
            }
            else {
                [string][bool]$Device.BluetoothPaired
            }

            $BluetoothLastWakeConnectText = if ($null -eq $Device.BluetoothLastWakeConnect) {
                "Not available"
            }
            elseif ($Device.BluetoothLastWakeConnect -is [datetime]) {
                ([datetime]$Device.BluetoothLastWakeConnect).ToString("MM/dd/yyyy hh:mm tt")
            }
            else {
                [string]$Device.BluetoothLastWakeConnect
            }

            $Lines += "Bluetooth connected now: $BluetoothConnectedText"
            $Lines += "Bluetooth paired: $BluetoothPairedText"
            $Lines += "Bluetooth last wake/connect: $BluetoothLastWakeConnectText"
        }

        $Lines -join [Environment]::NewLine
    }

    return ($Blocks -join ([Environment]::NewLine + [Environment]::NewLine))
}


function Get-DeviceIdentityKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Device
    )

    if (
        [string]$Device.VendorID -match '^[0-9A-Fa-f]{4}$' -and
        [string]$Device.ProductID -match '^[0-9A-Fa-f]{4}$'
    ) {
        return ("VIDPID|{0}|{1}" -f (
            [string]$Device.VendorID
        ).ToUpperInvariant(), (
            [string]$Device.ProductID
        ).ToUpperInvariant())
    }

    $Fallback = [string]$Device.FullDeviceData

    if ([string]::IsNullOrWhiteSpace($Fallback)) {
        $Fallback = [string]$Device.InstanceID
    }

    return "NONSTANDARD|$Fallback"
}

function ConvertTo-BaselineRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Devices
    )

    $Records = foreach ($Device in $Devices) {
        # Ignored models remain visible in Current Devices but are intentionally
        # excluded from the accepted baseline and change comparison.
        if ([string]$Device.Classification -eq 'Ignored') {
            continue
        }

        [PSCustomObject]@{
            Key            = Get-DeviceIdentityKey -Device $Device
            Classification = [string]$Device.Classification
            VendorID       = [string]$Device.VendorID
            ProductID      = [string]$Device.ProductID
            VendorName     = [string]$Device.VendorName
            ProductName    = [string]$Device.ProductName
            FullDeviceData = [string]$Device.FullDeviceData
        }
    }

    return @($Records | Sort-Object Key)
}

function ConvertTo-BaselineValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Records
    )

    $Value = if ($Records.Count -eq 0) {
        "[]"
    }
    else {
        @($Records) | ConvertTo-Json -Depth 4
    }

    if ($Value.Length -gt $MaximumMultiLineLength) {
        throw "The accepted baseline is too large for the NinjaOne multiline field. Required length: $($Value.Length); configured maximum: $MaximumMultiLineLength."
    }

    return $Value
}

function ConvertFrom-BaselineValue {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [Parameter(Mandatory)]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    try {
        $ParsedValue = ConvertFrom-Json -InputObject $Value -ErrorAction Stop
        $Parsed = @($ParsedValue)
    }
    catch {
        throw "The Device Detective baseline custom field does not contain valid baseline JSON: $($_.Exception.Message)"
    }

    foreach ($Record in $Parsed) {
        if ([string]::IsNullOrWhiteSpace([string]$Record.Key)) {
            throw 'The Device Detective baseline contains a record without an identity key.'
        }
    }

    return @($Parsed | Sort-Object Key)
}


function Get-BaselineRecordKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Record
    )

    # Both newly detected records and records stored in the NinjaOne baseline
    # already contain the canonical Key value. Prefer that value so the same
    # identity is compared exactly as it was originally written.
    $StoredKey = ([string]$Record.Key).Trim()

    if (-not [string]::IsNullOrWhiteSpace($StoredKey)) {
        return $StoredKey.ToUpperInvariant()
    }

    # Rebuild a standard key only as a compatibility fallback for an older or
    # manually edited baseline that does not contain the Key property.
    $VendorID = ([string]$Record.VendorID).Trim().ToUpperInvariant()
    $ProductID = ([string]$Record.ProductID).Trim().ToUpperInvariant()

    if (
        $VendorID -match '^[0-9A-F]{4}$' -and
        $ProductID -match '^[0-9A-F]{4}$'
    ) {
        return "VIDPID|$VendorID|$ProductID"
    }

    $Fallback = ([string]$Record.FullDeviceData).Trim()

    if ([string]::IsNullOrWhiteSpace($Fallback)) {
        throw 'A baseline record does not contain enough information to create an identity key.'
    }

    return "NONSTANDARD|$($Fallback.ToUpperInvariant())"
}

function New-MatchingBaselineComparison {
    [CmdletBinding()]
    param()

    return [PSCustomObject]@{
        Matches = $true
        Added   = @()
        Removed = @()
        Changed = @()
    }
}

function Compare-BaselineRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$BaselineRecords,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$CurrentRecords
    )

    $BaselineByKey = @{}
    $CurrentByKey = @{}

    foreach ($Record in $BaselineRecords) {
        $NormalizedKey = Get-BaselineRecordKey -Record $Record
        $BaselineByKey[$NormalizedKey] = $Record
    }

    foreach ($Record in $CurrentRecords) {
        $NormalizedKey = Get-BaselineRecordKey -Record $Record
        $CurrentByKey[$NormalizedKey] = $Record
    }

    $Added = @()
    $Removed = @()
    $Changed = @()

    foreach ($Key in $CurrentByKey.Keys) {
        if (-not $BaselineByKey.ContainsKey($Key)) {
            $Added += $CurrentByKey[$Key]
            continue
        }

        $Before = $BaselineByKey[$Key]
        $After = $CurrentByKey[$Key]

        $BeforeClassification = ([string]$Before.Classification).Trim()
        $AfterClassification = ([string]$After.Classification).Trim()
        $BeforeVendorName = ([string]$Before.VendorName).Trim()
        $AfterVendorName = ([string]$After.VendorName).Trim()
        $BeforeProductName = ([string]$Before.ProductName).Trim()
        $AfterProductName = ([string]$After.ProductName).Trim()

        if (
            -not $BeforeClassification.Equals($AfterClassification, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not $BeforeVendorName.Equals($AfterVendorName, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not $BeforeProductName.Equals($AfterProductName, [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            $Changed += [PSCustomObject]@{
                Key    = $Key
                Before = $Before
                After  = $After
            }
        }
    }

    foreach ($Key in $BaselineByKey.Keys) {
        if (-not $CurrentByKey.ContainsKey($Key)) {
            $Removed += $BaselineByKey[$Key]
        }
    }

    return [PSCustomObject]@{
        Matches = ($Added.Count -eq 0 -and $Removed.Count -eq 0 -and $Changed.Count -eq 0)
        Added   = @($Added | Sort-Object Key)
        Removed = @($Removed | Sort-Object Key)
        Changed = @($Changed | Sort-Object Key)
    }
}

function Format-BaselineDeviceSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Record
    )

    $Identifier = if (
        [string]$Record.VendorID -match '^[0-9A-Fa-f]{4}$' -and
        [string]$Record.ProductID -match '^[0-9A-Fa-f]{4}$'
    ) {
        "$($Record.VendorID)/$($Record.ProductID)"
    }
    else {
        [string]$Record.Key
    }

    return "$($Record.Classification): $Identifier - $($Record.VendorName) / $($Record.ProductName)"
}

function Format-BaselineChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Comparison
    )

    if ($Comparison.Matches) {
        return 'Current devices match the accepted baseline.'
    }

    $Lines = @('Device state differs from the accepted baseline.')

    if ($Comparison.Added.Count -gt 0) {
        $Lines += ''
        $Lines += 'Added:'
        $Lines += @($Comparison.Added | ForEach-Object { '- ' + (Format-BaselineDeviceSummary -Record $_) })
    }

    if ($Comparison.Removed.Count -gt 0) {
        $Lines += ''
        $Lines += 'Removed:'
        $Lines += @($Comparison.Removed | ForEach-Object { '- ' + (Format-BaselineDeviceSummary -Record $_) })
    }

    if ($Comparison.Changed.Count -gt 0) {
        $Lines += ''
        $Lines += 'Classification or friendly-name changes:'
        $Lines += @($Comparison.Changed | ForEach-Object {
            '- {0} -> {1}' -f (
                Format-BaselineDeviceSummary -Record $_.Before
            ), (
                Format-BaselineDeviceSummary -Record $_.After
            )
        })
    }

    return ($Lines -join [Environment]::NewLine)
}

function Get-InventoryStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
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
            Set-DeviceDetectiveProperty -Name $CustomFields.DatabaseHash -Value "" -Type "Text"
            $ForceDatabaseRefresh = $true
        }

        "Approve Current Baseline" {
            Write-DeviceDetectiveLog "A current-baseline approval was requested."
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

    $DatabaseRefreshedForMissingModel = $false
    $MissingValidModelsBeforeRefresh = @(
        $CurrentDevices | Where-Object {
            $_.HasValidVidPid -and -not $_.LookupMatched
        }
    )

    $DatabaseAgeHours = ((Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $DatabasePath).LastWriteTimeUtc).TotalHours
    $MissingModelRefreshAllowed = $DatabaseAgeHours -ge $MinimumMissingModelRefreshAgeHours

    if (
        $MissingValidModelsBeforeRefresh.Count -gt 0 -and
        -not $DatabaseNeedsDownload -and
        $MissingModelRefreshAllowed
    ) {
        Write-DeviceDetectiveLog `
            -Level "WARNING" `
            -Message "$($MissingValidModelsBeforeRefresh.Count) valid VID/PID model(s) were not found in the local database. The cache is $([math]::Round($DatabaseAgeHours, 1)) hour(s) old, so the database will be refreshed once and lookup retried."

        try {
            $DatabaseResult = Install-DeviceDatabase
            Set-DeviceDetectiveProperty -Name $CustomFields.DatabaseHash -Value $DatabaseResult.Hash -Type "Text"
            $DatabaseRefreshedForMissingModel = $true
            $DatabaseNeedsDownload = $true

            $Database = @(Import-DeviceDatabase -Path $DatabasePath)
            $CurrentDevices = @(Resolve-DeviceModels -Devices $CurrentDevices -Database $Database)
        }
        catch {
            Write-DeviceDetectiveLog `
                -Level "WARNING" `
                -Message "Database refresh for missing VID/PID models failed. Continuing with the trusted local results. Error: $($_.Exception.Message)"
        }
    }
    elseif ($MissingValidModelsBeforeRefresh.Count -gt 0 -and -not $DatabaseNeedsDownload) {
        Write-DeviceDetectiveLog `
            -Level "WARNING" `
            -Message "$($MissingValidModelsBeforeRefresh.Count) valid VID/PID model(s) were not found, but the database cache is only $([math]::Round($DatabaseAgeHours, 1)) hour(s) old. Skipping GitHub refresh to prevent repeated downloads."
    }

    $InventoryStatus = Get-InventoryStatus -Devices $CurrentDevices
    $CurrentDeviceText = Limit-MultiLineValue -Value (Format-CurrentDevices -Devices $CurrentDevices)

    $ApprovedCount = @($CurrentDevices | Where-Object { $_.Classification -eq "Approved" }).Count
    $KnownCount = @($CurrentDevices | Where-Object { $_.Classification -eq "Known" }).Count
    $UnknownCount = @($CurrentDevices | Where-Object { $_.Classification -eq "Unknown" }).Count
    $ProhibitedCount = @($CurrentDevices | Where-Object { $_.Classification -eq "Prohibited" }).Count
    $IgnoredCount = @($CurrentDevices | Where-Object { $_.Classification -eq "Ignored" }).Count

    $ReviewDevices = @(
        $CurrentDevices | Where-Object { $_.Classification -in @("Known", "Unknown", "Prohibited") }
    )

    $NoCurrentDevices = $CurrentDevices.Count -eq 0

    $ReviewSummary = if ($NoCurrentDevices) {
        "No Mouse, Keyboard, or HIDClass device models were detected in the current inventory."
    }
    elseif ($ReviewDevices.Count -eq 0) {
        "No non-approved devices are present in the current inventory."
    }
    else {
        @(
            "Non-approved devices in current inventory:"
            $ReviewDevices | ForEach-Object {
                $VidPid = if ($_.ProductID) { "$($_.VendorID)/$($_.ProductID)" } else { [string]$_.VendorID }
                "- $($_.Classification): $VidPid - $($_.VendorName) / $($_.ProductName)"
            }
        ) -join [Environment]::NewLine
    }

    $BaselineValue = [string](Get-DeviceDetectiveProperty -Name $CustomFields.Baseline -Type "MultiLine")
    $BaselineExists = -not [string]::IsNullOrWhiteSpace($BaselineValue)
    $BaselineRecords = @(ConvertFrom-BaselineValue -Value $BaselineValue)
    $CurrentBaselineRecords = @(ConvertTo-BaselineRecords -Devices $CurrentDevices)
    $BaselineComparison = Compare-BaselineRecords -BaselineRecords $BaselineRecords -CurrentRecords $CurrentBaselineRecords
    $ReportedBaselineComparison = $BaselineComparison

    $AllCurrentDevicesAutomaticallyAcceptable = (
        -not $NoCurrentDevices -and
        @(
            $CurrentDevices | Where-Object { $_.Classification -notin @("Approved", "Ignored") }
        ).Count -eq 0
    )

    $BaselineActionSummary = "No baseline change was made."
    $Status = $InventoryStatus
    $ResetActionAfterRun = $Action -in @("Refresh Database", "Reset Local Data")

    if ($Action -eq "Approve Current Baseline") {
        $ResetActionAfterRun = $true

        if ($ProhibitedCount -gt 0) {
            $Status = "Prohibited Device"
            $BaselineActionSummary = "Manual baseline approval was rejected because the current state contains a prohibited device."
            Write-DeviceDetectiveLog -Level "WARNING" -Message $BaselineActionSummary
        }
        elseif ($NoCurrentDevices) {
            $NewBaselineValue = ConvertTo-BaselineValue -Records @()
            Set-DeviceDetectiveProperty -Name $CustomFields.Baseline -Value $NewBaselineValue -Type "MultiLine"
            $BaselineRecords = @()
            $BaselineExists = $true
            $BaselineComparison = New-MatchingBaselineComparison
            $ReportedBaselineComparison = $BaselineComparison
            $Status = "Normal"
            $BaselineActionSummary = "An empty device inventory was accepted as the baseline through the NinjaOne approval action."
            Write-DeviceDetectiveLog $BaselineActionSummary
        }
        else {
            $NewBaselineValue = ConvertTo-BaselineValue -Records $CurrentBaselineRecords
            Set-DeviceDetectiveProperty -Name $CustomFields.Baseline -Value $NewBaselineValue -Type "MultiLine"
            $BaselineRecords = $CurrentBaselineRecords
            $BaselineExists = $true
            $BaselineComparison = New-MatchingBaselineComparison
            $ReportedBaselineComparison = $BaselineComparison
            $Status = "Normal"
            $BaselineActionSummary = "The current device state was accepted as the baseline through the NinjaOne approval action."
            Write-DeviceDetectiveLog $BaselineActionSummary
        }
    }
    elseif (-not $BaselineExists) {
        if ($NoCurrentDevices) {
            $Status = "Review Required"
            $BaselineActionSummary = "No baseline was created because no monitored device models were detected."
            Write-DeviceDetectiveLog -Level "WARNING" -Message $BaselineActionSummary
        }
        elseif ($AllCurrentDevicesAutomaticallyAcceptable) {
            $NewBaselineValue = ConvertTo-BaselineValue -Records $CurrentBaselineRecords
            Set-DeviceDetectiveProperty -Name $CustomFields.Baseline -Value $NewBaselineValue -Type "MultiLine"
            $BaselineRecords = $CurrentBaselineRecords
            $BaselineExists = $true
            $BaselineComparison = New-MatchingBaselineComparison
            $ReportedBaselineComparison = $BaselineComparison
            $Status = "Normal"
            $BaselineActionSummary = "The initial baseline was created automatically because all current devices are Approved or Ignored."
            Write-DeviceDetectiveLog $BaselineActionSummary
        }
        else {
            $BaselineActionSummary = "No baseline exists. IT review is required before the current state can be accepted."
        }
    }
    elseif ($NoCurrentDevices) {
        if ($BaselineComparison.Matches) {
            # An explicitly accepted empty baseline is a valid normal state for
            # headless systems. Zero devices are never auto-baselined, but once
            # manually approved, future successful zero-device scans should match.
            $Status = "Normal"
            $BaselineActionSummary = "No baseline change was made. The accepted baseline intentionally contains no monitored device models."
        }
        else {
            $Status = "Review Required"
            $BaselineActionSummary = "The accepted baseline was retained because no monitored device models were detected."
            Write-DeviceDetectiveLog -Level "WARNING" -Message $BaselineActionSummary
        }
    }
    elseif ($BaselineComparison.Matches) {
        # A manually accepted Known or Unknown model remains normal while the
        # current state continues to match the accepted baseline.
        $Status = if ($ProhibitedCount -gt 0) { "Prohibited Device" } else { "Normal" }
        $BaselineActionSummary = "No baseline change was made."
    }
    elseif ($AllCurrentDevicesAutomaticallyAcceptable) {
        $NewBaselineValue = ConvertTo-BaselineValue -Records $CurrentBaselineRecords
        Set-DeviceDetectiveProperty -Name $CustomFields.Baseline -Value $NewBaselineValue -Type "MultiLine"
        $BaselineRecords = $CurrentBaselineRecords
        $BaselineComparison = New-MatchingBaselineComparison
        $ReportedBaselineComparison = $BaselineComparison
        $Status = "Normal"
        $BaselineActionSummary = "The accepted baseline was updated automatically because all current devices are Approved or Ignored."
        Write-DeviceDetectiveLog $BaselineActionSummary
    }
    else {
        $Status = $InventoryStatus
        $BaselineActionSummary = "The accepted baseline was retained because the changed state contains a Known, Unknown, or Prohibited device."
    }

    $BaselineChangeSummary = if (-not $BaselineExists) {
        "No accepted baseline exists for comparison."
    }
    else {
        Format-BaselineChanges -Comparison $ReportedBaselineComparison
    }

    $ReviewContextSummary = if (
        $ReviewDevices.Count -gt 0 -and
        $BaselineExists -and
        $ReportedBaselineComparison.Matches -and
        $Status -eq "Normal"
    ) {
        "These non-approved devices are part of the accepted baseline for this computer."
    }
    elseif ($ReviewDevices.Count -gt 0) {
        "These devices are not globally approved and the current inventory requires review."
    }
    else {
        $null
    }

    $Details = @(
        "Device Detective device inventory and baseline evaluation completed successfully."
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
        $ReviewContextSummary
        ""
        "Baseline exists: $BaselineExists"
        $BaselineActionSummary
        $BaselineChangeSummary
        ""
        "Database path: $DatabasePath"
        "Database hash: $($DatabaseResult.Hash)"
        "Database rows: $($DatabaseResult.TotalRows)"
        "Valid VID/PID product rows: $($DatabaseResult.ProductRows)"
        "Requested action: $Action"
        "GitHub contacted: $DatabaseNeedsDownload"
        "Database refreshed because valid VID/PID models were missing: $DatabaseRefreshedForMissingModel"
        "Database age before missing-model refresh check: $([math]::Round($DatabaseAgeHours, 1)) hours"
        "Minimum age before automatic missing-model refresh: $MinimumMissingModelRefreshAgeHours hours"
        ""
        "Note: specialized reporting for keyboards or mice removed from otherwise unused computers is planned for a future version."
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

    if ($ResetActionAfterRun) {
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
