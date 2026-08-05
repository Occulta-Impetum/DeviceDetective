Below is a ready-to-paste `README.md` that reflects the project’s current state without claiming the unfinished NinjaOne alerting and Zendesk portions are complete.

````markdown
# Device Detective

Device Detective is a PowerShell-based endpoint monitoring tool designed to run through NinjaOne.

It inventories connected keyboards, mice, and HID-class devices, resolves their USB or Bluetooth VID/PID information against a centrally maintained database, and compares the current inventory with an accepted device baseline.

The project was created to replace a Windows startup script that could delay login or leave computers stuck at **Please wait** when network or Active Directory dependencies were slow.

## Current project status

Device Detective is currently under development and pilot testing.

The following features are working:

- NinjaOne custom-field integration
- GitHub-hosted device database
- Local database caching
- SHA-256 database validation
- Local database tamper detection
- Manual database refresh through NinjaOne
- Mouse, keyboard, and HID-class enumeration
- Standard USB VID/PID parsing
- Bluetooth VID/PID parsing
- Consolidation of duplicate HID interfaces
- Exclusion of generic Bluetooth HID child interfaces
- Friendly-name and classification lookup
- Current-device reporting
- Accepted device baselines
- Automatic baseline creation for approved devices
- Manual baseline approval
- Added, removed, and reclassified device reporting

The following features are still planned:

- NinjaOne alert conditions
- Zendesk ticket creation and clearing
- Scheduled pilot deployment
- Specialized reporting for computers missing expected keyboards or mice
- Broader production testing and documentation

## How it works

Device Detective follows this general workflow:

1. NinjaOne runs the PowerShell script as `SYSTEM`.
2. The script creates a local working directory under `ProgramData`.
3. The device database is downloaded from GitHub when needed.
4. The database is validated and cached locally.
5. The local database hash is compared with a trusted SHA-256 hash stored in NinjaOne.
6. Currently present Mouse, Keyboard, and HIDClass devices are collected.
7. USB and supported Bluetooth identifiers are converted into normalized VID/PID values.
8. Duplicate interfaces representing the same device model are consolidated.
9. Devices are matched against `device-database.csv`.
10. The current inventory is compared with the accepted NinjaOne baseline.
11. Status, inventory, baseline, and comparison details are written to NinjaOne custom fields.

Routine runs normally use the trusted local database and do not contact GitHub.

## Device classifications

The database supports the following classifications:

| Classification | Meaning |
|---|---|
| `Approved` | The device model is approved across all monitored computers. |
| `Known` | The model has been identified, but it is not globally approved. |
| `Prohibited` | The model is explicitly forbidden, such as a known mouse jiggler. |
| `Ignored` | The model is intentionally excluded from baseline comparisons. |
| `Unknown` | Assigned by the script when a valid device model cannot be resolved from the database. |

`Unknown` normally does not need to be entered into the CSV. It is assigned dynamically when no matching model is found.

## Repository contents

```text
DeviceDetective
├── DeviceDetective.ps1
├── device-database.csv
└── README.md
````

### `DeviceDetective.ps1`

The PowerShell script deployed and executed through NinjaOne.

### `device-database.csv`

The central VID/PID friendly-name and classification database.

## Requirements

* Windows endpoint
* Windows PowerShell 5.1 or later
* NinjaOne agent
* NinjaOne custom fields configured as documented below
* Internet access to `raw.githubusercontent.com` when a database download is required
* Script execution as `SYSTEM`

## NinjaOne script variable

Create the following NinjaOne script variable:

| Setting         | Value        |
| --------------- | ------------ |
| Display name    | `GitHub URL` |
| Calculated name | `githubUrl`  |
| Type            | String/Text  |
| Required        | Yes          |

Example value:

```text
https://raw.githubusercontent.com/Occulta-Impetum/DeviceDetective-Database/refs/heads/main/device-database.csv
```

The script reads this value through:

```powershell
$env:githubUrl
```

The GitHub URL is intentionally not hardcoded into the script.

## NinjaOne custom fields

Create the following device custom fields:

| Display name                     | Field name                      | Type       |
| -------------------------------- | ------------------------------- | ---------- |
| Device Detective Action          | `deviceDetectiveAction`         | Drop-down  |
| Device Detective Baseline        | `deviceDetectiveBaseline`       | Multi-line |
| Device Detective Current Devices | `deviceDetectiveCurrentDevices` | Multi-line |
| Device Detective Database Hash   | `deviceDetectiveDatabaseHash`   | Text       |
| Device Detective Details         | `deviceDetectiveDetails`        | Multi-line |
| Device Detective Last Run        | `deviceDetectiveLastRun`        | Date/Time  |
| Device Detective Status          | `deviceDetectiveStatus`         | Drop-down  |

Scripts must have permission to read and write these fields.

### Action values

Configure `deviceDetectiveAction` with these exact values:

```text
None
Approve Current Baseline
Refresh Database
Reset Local Data
```

### Status values

Configure `deviceDetectiveStatus` with these exact values:

```text
Normal
Review Required
Prohibited Device
Error
```

Drop-down values must match exactly, including capitalization and spacing.

## Action behavior

### `None`

Runs normal inventory, classification, and baseline evaluation.

### `Approve Current Baseline`

Accepts the current device inventory as the baseline for that computer.

This does not approve a device model globally. A device may remain classified as `Known` while being accepted as part of one computer's baseline.

Manual approval is rejected when a `Prohibited` device is present.

### `Refresh Database`

Downloads and validates the current GitHub database immediately, updates the local cache, and stores the new trusted hash in NinjaOne.

The action is reset to `None` after processing.

### `Reset Local Data`

Removes locally cached Device Detective data and clears the related baseline, current-device, and database-hash fields.

The endpoint then behaves like a new deployment and downloads a fresh database.

## Baseline behavior

### No existing baseline

When every current device is classified as `Approved` or `Ignored`, the script creates the initial baseline automatically.

When a `Known`, `Unknown`, or `Prohibited` device is present, the baseline is not created automatically.

### Existing baseline matches

The status remains `Normal`, and the baseline is not rewritten.

A `Known` or `Unknown` model that was manually accepted may remain visible in the details field even though the computer is currently normal.

### Changed inventory containing only approved devices

The script automatically accepts the new device state and updates the baseline.

### Changed inventory containing a known or unknown device

The existing baseline is retained, and the status becomes `Review Required`.

### Prohibited device detected

The existing baseline is retained, and the status becomes `Prohibited Device`.

## Device database format

The CSV uses the following columns:

```csv
VendorID,ProductID,VendorName,ProductName,Classification,Notes
```

Example:

```csv
03F0,584A,"HP, Inc","HP Mouse",Approved,"Company provided"
3434,02A0,"Keychron, Inc.","K10 Pro",Approved,""
1532,0504,"Razer USA, Ltd","Kraken 7.1 Chroma",Known,""
```

### Formatting rules

* `VendorID` should be four hexadecimal characters.
* `ProductID` should be four hexadecimal characters for product records.
* IDs should be stored as text so leading zeroes are preserved.
* Use uppercase hexadecimal values for consistency.
* Do not include `VID_` or `PID_` prefixes.
* Use only the documented classification values.
* Vendor-only reference rows may have a blank ProductID and classification.
* Save the file as UTF-8 CSV.
* Disable automatic numeric and scientific-notation conversion when editing in Excel.

## Database caching and validation

The local working directory is:

```text
C:\ProgramData\SysAdminBot\DeviceDetective
```

The path is created using:

```powershell
Join-Path $env:ProgramData "SysAdminBot\DeviceDetective"
```

Typical local files include:

```text
device-database.csv
DeviceDetective.log
```

The script:

* Downloads to a temporary file
* Validates required CSV columns
* Validates classification values
* Confirms valid VID/PID product records exist
* Calculates a SHA-256 hash
* Replaces the local cache only after validation succeeds
* Stores the trusted hash in NinjaOne
* Detects changes made directly to the local CSV
* Restores the official GitHub version after a hash mismatch

If GitHub is unavailable and a trusted local copy exists, the script continues using the local database.

## Database refresh behavior

Device Detective avoids downloading the database during every scheduled run.

GitHub is contacted when:

* No local database exists
* The trusted NinjaOne hash is empty
* The local database fails validation
* The local hash does not match the trusted hash
* `Refresh Database` is selected
* A valid missing VID/PID is detected and the configured minimum refresh age has passed

Unexpected or generic Bluetooth identifiers do not force a database refresh.

## Bluetooth handling

Device Detective supports several Bluetooth HID identifier formats and attempts to extract a usable four-character VID and PID.

Interfaces that normalize to the same VID/PID are consolidated into one device model.

Generic Bluetooth HID or BLE GATT child interfaces that do not expose a reliable model identifier may be excluded when they only duplicate an already detected physical device.

## NinjaOne field notes

NinjaOne Multi-line custom fields may be returned to PowerShell as a `System.Object[]` containing one element per line.

The script rejoins those lines into a single string before parsing baseline JSON.

Multi-line fields have a 10,000-character platform limit. Device Detective uses a lower internal limit to provide additional safety.

## Suggested deployment process

1. Create the required NinjaOne custom fields.
2. Configure the drop-down values exactly as documented.
3. Add the GitHub URL script variable.
4. Upload the tested PowerShell script to NinjaOne.
5. Run the automation as `SYSTEM`.
6. Test on an IT-owned computer.
7. Review the current-device and details fields.
8. Test database refresh and tamper protection.
9. Test approved, known, unknown, and prohibited devices.
10. Pilot on a small NinjaOne policy group.
11. Configure NinjaOne alert conditions only after the inventory results are reliable.
12. Deploy gradually to production endpoints.

A 15-minute schedule is currently planned, but the final schedule should be confirmed before production deployment.

## Security considerations

* Do not store credentials, API tokens, endpoint inventories, usernames, or confidential information in the public repository.
* The public database should contain only hardware identifiers, friendly names, classifications, and non-sensitive notes.
* Keep Zendesk or other service credentials out of the PowerShell script.
* NinjaOne should handle alerting and ticket integration separately.
* Device Detective classifies device models, not individual physical units.
* Approval is based on VID/PID and therefore applies to every unit reporting the same model identifiers.
* This tool assists with monitoring and review but should not be treated as a complete device-control or data-loss-prevention system.

## Known limitations

* Some hardware does not expose a reliable VID/PID.
* Composite devices may expose multiple Windows interfaces.
* Bluetooth device reporting varies by hardware and Windows driver.
* A VID/PID normally identifies a model rather than a unique physical unit.
* Current monitoring includes Mouse, Keyboard, and HIDClass devices, so some headsets and other HID-capable hardware may also appear.
* Removal of approved devices currently may be accepted automatically when the remaining inventory is otherwise approved.
* Specialized reporting for computers missing expected keyboards or mice has not yet been implemented.
* NinjaOne alerts and Zendesk ticket workflows are not yet included in the current development build.

## Planned improvements

* NinjaOne alert-state configuration
* Zendesk ticket creation and clearing
* Missing keyboard and mouse reporting
* Additional device-category filtering
* Broader Bluetooth testing
* Pilot and production deployment documentation
* Changelog and release versioning
* Additional reporting and audit history

## License

No license has currently been assigned to this project.

