# Device Detective

Device Detective is a PowerShell-based endpoint monitoring system deployed through NinjaOne. It inventories currently present keyboards, mice, and HID-class devices, resolves supported USB and Bluetooth identifiers against a centrally maintained VID/PID database, compares the result with an accepted endpoint baseline, and exposes actionable state through NinjaOne custom fields and Script Result conditions.

It replaced an older Windows startup script that could delay login or leave computers at **Please wait** when network or Active Directory dependencies were unavailable.

## Current project status

Device Detective is operational in production.

Current production behavior includes:

- Hourly execution, 24 hours a day, through NinjaOne
- Mouse, Keyboard, and HIDClass enumeration
- USB and supported Bluetooth VID/PID parsing
- Device-model consolidation
- Central database lookup and classification
- Trusted local database caching with SHA-256 validation
- Endpoint-specific accepted baselines
- Automatic acceptance of defined safe changes
- NinjaOne custom-field reporting
- A separate Alert Evaluator for NinjaOne Script Result conditions
- Native NinjaOne-to-Zendesk ticket creation
- Duplicate suppression during an active condition
- Reset updates on the original ticket
- Startup/reboot safeguards for transient zero-device and custom-field failures

The following work remains planned or under observation:

- Validate the 60-minute Alert Evaluator startup grace period during a future comparable reboot and patch cycle
- Develop reliable stale Bluetooth-pair detection
- Document when technicians should approve an endpoint baseline versus approve a VID/PID model globally
- Design missing expected keyboard/mouse reporting without alerting on every ordinary device change
- Continue production-driven filtering and reporting refinements

## Repository contents

```text
DeviceDetective
├── DeviceDetective.ps1
├── DeviceDetective_AlertEvaluator.ps1
├── device-database.csv
└── README.md
```

### `DeviceDetective.ps1`

The main inventory, classification, database, baseline, and NinjaOne custom-field script.

### `DeviceDetective_AlertEvaluator.ps1`

The helper used by the NinjaOne Script Result condition. It reads Device Detective fields and emits one concise result for alert evaluation. It does not enumerate devices, modify baselines, contact Zendesk directly, or change Device Detective custom fields.

### `device-database.csv`

A repository copy of the VID/PID database. Production endpoints obtain their configured database URL from the NinjaOne `githubUrl` script variable.

## Requirements

- Windows endpoint
- Windows PowerShell 5.1 or later
- NinjaOne agent
- Script execution as `SYSTEM`
- Required NinjaOne custom fields and exact drop-down values
- Read/write custom-field permission for the main script
- Read permission for the Alert Evaluator
- Internet access to the configured HTTPS raw database URL when a download is required
- A NinjaOne Script Result condition for alert evaluation
- NinjaOne's native Zendesk action when ticket creation is required

## NinjaOne script variable

Configure this script variable for `DeviceDetective.ps1`:

| Setting | Value |
|---|---|
| Display name | `GitHub URL` |
| Calculated name | `githubUrl` |
| Type | String/Text |
| Required | Yes |

Current database URL format:

```text
https://raw.githubusercontent.com/Occulta-Impetum/DeviceDetective-Database/refs/heads/main/device-database.csv
```

The script reads the value from:

```powershell
$env:githubUrl
```

The URL is intentionally not hardcoded into the script.

## NinjaOne custom fields

Create these device custom fields:

| Display name | Field name | Type |
|---|---|---|
| Device Detective Status | `deviceDetectiveStatus` | Drop-down |
| Device Detective Action | `deviceDetectiveAction` | Drop-down |
| Device Detective Last Run | `deviceDetectiveLastRun` | Date/Time |
| Device Detective Alert Devices | `deviceDetectiveAlertDevices` | Multi-line |
| Device Detective Current Devices | `deviceDetectiveCurrentDevices` | Multi-line |
| Device Detective Details | `deviceDetectiveDetails` | Multi-line |
| Device Detective Baseline | `deviceDetectiveBaseline` | Multi-line |
| Device Detective Database Hash | `deviceDetectiveDatabaseHash` | Text |

Technicians should be able to read every field, write Device Detective Action, and edit a baseline only through the documented workflow. Scripts require the permissions appropriate to their reads and writes.

### Status values

Configure `deviceDetectiveStatus` with these exact values:

```text
Normal
Review Required
Prohibited Device
Error
```

- `Normal`: The current inventory matches the accepted state, or only safe changes were accepted automatically.
- `Review Required`: A new Known or Unknown model or another unsafe classification change needs technician review.
- `Prohibited Device`: A currently detected model is classified as Prohibited.
- `Error`: The main script could not safely complete inventory or state processing.

### Action values

Configure `deviceDetectiveAction` with these exact values:

```text
None
Approve Current Baseline
Refresh Database
Reset Local Data
```

- `None`: Perform the normal scheduled workflow.
- `Approve Current Baseline`: Accept the current endpoint inventory as its baseline.
- `Refresh Database`: Download, validate, and use the current central database.
- `Reset Local Data`: Remove local Device Detective data, clear relevant fields, and rebuild from a fresh database during the same run.

Drop-down values must match exactly, including capitalization and spacing.

## Important approval behavior

Endpoint baseline approval and global database approval are different:

- Endpoint baseline approval accepts a model only for the selected computer.
- Changing a model to Approved in the central database applies globally to every endpoint reporting that VID/PID.
- A Known model may be accepted into an endpoint baseline without becoming globally Approved.
- A Prohibited model cannot be accepted through `Approve Current Baseline`.
- An intentionally empty inventory can be manually accepted for a legitimate headless computer.

### Open implementation discrepancy

The current `DeviceDetective.ps1` blocks baseline approval when a Prohibited device is present, but it does **not** currently block an Unknown device from being accepted. The published technician documentation states that Unknown and Prohibited devices cannot be approved into the current baseline.

Until the script is aligned with that documented rule, technicians must not use `Approve Current Baseline` while an Unknown device is present. This is an open code/documentation issue.

## Main-script workflow

`DeviceDetective.ps1` performs this general workflow:

1. Creates `C:\ProgramData\SysAdminBot\DeviceDetective` if needed.
2. Reads the requested NinjaOne action.
3. Validates the trusted local database and its stored SHA-256 hash.
4. Downloads and validates a replacement database when required.
5. Reads the accepted endpoint baseline.
6. Enumerates present Mouse, Keyboard, and HIDClass devices.
7. Retries a zero-device result as many as three times, with 10-second delays.
8. Normalizes supported USB and Bluetooth identifiers.
9. Consolidates interfaces representing the same VID/PID model.
10. Applies internal, generic, Surface, converted-device, and VHF filtering rules.
11. Resolves devices against the local database.
12. Optionally refreshes an old database when missing or Known/Unknown valid VID/PID models are present.
13. Compares the current device records with the accepted baseline.
14. Determines safe and unsafe changes.
15. Writes inventory, alert devices, status, details, last-run time, hash, and any baseline update to NinjaOne.

Routine runs normally use the trusted local database and do not contact GitHub.

## Device classifications

| Classification | Meaning |
|---|---|
| `Approved` | The VID/PID model is approved globally. |
| `Known` | The model is identified but not globally approved. |
| `Unknown` | The script could not resolve the current model to an applicable classified database record. |
| `Prohibited` | The model is forbidden, including known mouse jigglers. |
| `Ignored` | The record or interface is intentionally excluded from actionable monitoring. |

The CSV accepts `Approved`, `Known`, `Prohibited`, and `Ignored`. `Unknown` is normally assigned dynamically and does not need to be entered in the database.

## Baseline behavior

Baselines represent device models rather than unique physical units.

### No baseline

- Approved/Ignored-only inventories can create an initial baseline automatically.
- A Known, Unknown, or Prohibited inventory is not automatically baselined.
- A zero-device result does not create a baseline automatically.
- IT can explicitly approve an empty baseline for a legitimate headless endpoint.

### Matching baseline

- Matching identities and classifications return Normal unless a current Prohibited model is present.
- A previously accepted Known or Unknown model can remain Normal while it continues to match the endpoint baseline.
- VendorName and ProductName are descriptive metadata rather than identity.
- Metadata-only corrections are synchronized into the baseline without creating Review Required.

### Safe changes

The following changes can update an existing baseline automatically:

- A newly added Approved model
- A classification change to Approved
- A still-present model changing to Ignored
- Descriptive metadata corrections

An unchanged accepted Known or Unknown model does not block an unrelated safe change elsewhere on the endpoint.

### Reviewable changes

The following remain reviewable:

- A newly added Known model
- A newly added Unknown model
- A newly detected Prohibited model
- A classification change to Known, Unknown, or Prohibited

Removal of an Approved device is **not currently an alert condition**. The accepted baseline is retained, but the current implementation does not contain the expectation framework needed to decide whether a missing approved device should create a ticket.

## Zero-device startup safeguard

A successful Plug and Play query can temporarily return zero monitored models while Windows is still initializing after boot or wake.

The script therefore:

1. Makes as many as three enumeration attempts.
2. Waits 10 seconds between zero-result attempts.
3. Continues normally if devices appear.
4. Treats persistent zero results as inconclusive when a non-empty accepted baseline exists.
5. Exits successfully without overwriting Status, Current Devices, Alert Devices, Details, Last Run, or Baseline.

This preserves the last authoritative state and prevents a transient empty snapshot from resetting or creating an alert. Explicit empty-baseline approval for a legitimate headless computer remains supported.

## Alert Devices field

`deviceDetectiveCurrentDevices` contains the complete monitored inventory from the latest authoritative run.

`deviceDetectiveAlertDevices` contains only the current models responsible for Review Required or Prohibited Device. Normal and Error runs clear Alert Devices so stale device data is not reused.

The Alert Evaluator uses Alert Devices rather than parsing the human-readable Details field.

## Alert Evaluator behavior

The Alert Evaluator emits exactly one result line:

- Normal: `DEVICE_DETECTIVE_NORMAL`
- Any non-Normal production state: a line beginning with `DEVICE_DETECTIVE_ALERT`

For alert states, the result includes:

- Device Detective status
- Most recent locally available active user
- Alert Devices summary
- Concise Details only when Device Detective status is Error

The evaluator exits successfully for controlled Device Detective alert states so they are not treated as script-execution failures.

### Post-reboot field safeguard

NinjaOne can run the evaluator before custom-field metadata is available after a reboot. The evaluator therefore:

1. Tries the Status field as many as three times.
2. Waits 10 seconds between attempts.
3. Caches every successful complete evaluation in:
   `C:\ProgramData\SysAdminBot\DeviceDetective\AlertEvaluator.last-result.txt`
4. Reuses the cached result when field access still fails during the first 60 minutes after Windows startup.
5. Temporarily emits Normal during that grace period on a new endpoint with no cache.
6. Emits Helper Script Error when persistent field access failure occurs outside the grace period.

The 60-minute value was selected after `LBT600` remained unable to resolve the field beyond the earlier 15-minute window during a reboot and patch cycle. It remains under production observation.

## Device database format

The CSV columns are:

```csv
VendorID,ProductID,VendorName,ProductName,Classification,Notes
```

Example:

```csv
03F0,584A,"HP, Inc","HP Mouse",Approved,"Company provided"
3434,02A0,"Keychron, Inc.","K10 Pro",Approved,""
1532,0504,"Razer USA, Ltd","Kraken 7.1 Chroma",Known,""
```

Formatting rules:

- VendorID should be four hexadecimal characters for valid VID records.
- ProductID should be four hexadecimal characters for product records.
- Store IDs as text so leading zeroes remain intact.
- Use uppercase hexadecimal values for consistency.
- Do not include `VID_` or `PID_` prefixes.
- Use only the classifications accepted by the CSV validator.
- Vendor-only reference rows may have a blank ProductID and classification.
- Save as UTF-8 CSV.
- Prevent spreadsheet software from converting IDs to numbers or scientific notation.

## Database caching and refresh

The local working directory is:

```text
C:\ProgramData\SysAdminBot\DeviceDetective
```

Typical files include:

```text
device-database.csv
DeviceDetective.log
AlertEvaluator.last-result.txt
```

The main script:

- Downloads to a temporary file
- Validates required columns
- Validates classification values
- Confirms at least one valid VID/PID product record
- Calculates SHA-256
- Replaces the local database only after validation succeeds
- Stores the trusted hash in NinjaOne
- Detects local modification or corruption
- Replaces an untrusted local copy with the configured central copy

GitHub is contacted when:

- No local database exists
- The trusted NinjaOne hash is blank
- Local validation fails
- The local hash differs from the trusted hash
- Refresh Database is requested
- A valid missing, Known, or Unknown VID/PID model is present and the cache is at least 24 hours old

After an automatic refresh, current devices are resolved again before status and baseline decisions. Failure of the age-gated automatic review-candidate refresh logs a warning and continues with the trusted local results. A required initial, forced, invalid-cache, or tamper-recovery download failure puts the main script into Error.

## Bluetooth and interface handling

Device Detective supports standard USB, Bluetooth, and Bluetooth LE identifier forms where Windows exposes usable VID/PID data.

It can enrich supported Bluetooth records with:

- Friendly name
- Bluetooth address
- Paired state
- Current connection state
- Last validated wake/connect timestamp

Bluetooth connection state is informational only. A legitimate sleeping battery-powered peripheral can appear disconnected, and Windows may continue exposing an obsolete paired HID device as present. Stale-pair removal is therefore not enabled.

Additional filtering includes:

- Generic Bluetooth HID/BLE children without usable model identity
- Duplicate USB/Bluetooth interfaces for the same model
- Microsoft Surface internal touch, pen, button, keyboard, virtual HID, and related interfaces, only on identified Surface hardware
- Nonstandard `CONVERTEDDEVICE` records without valid VID/PID
- A `HID_DEVICE_SYSTEM_VHF` child only when parent tracing proves it belongs to an independently represented physical VID/PID model

Unexplained VHF devices remain visible for review.

## NinjaOne and Zendesk alert lifecycle

Production uses a NinjaOne Script Result condition based on the Alert Evaluator:

- Normal emits only `DEVICE_DETECTIVE_NORMAL`.
- Non-Normal states emit `DEVICE_DETECTIVE_ALERT`.
- NinjaOne's native Create Zendesk Ticket action creates the ticket.
- Repeated evaluation during the same active condition does not create duplicate tickets.
- Condition reset is appended to the original ticket and does not automatically close it.
- Ticket templates use the `ninjaone_alert` tag.
- Zendesk requester-notification triggers exclude `ninjaone_alert` tickets.
- Ticket-template retrigger behavior has been adjusted so renewed conditions remain actionable instead of being lost in an earlier Open or Solved ticket.

Zendesk credentials and ticket API logic do not belong in either PowerShell script.

## Deployment and validation

1. Create the required custom fields and exact drop-down values.
2. Grant the required script permissions.
3. Configure the `githubUrl` variable for the main script.
4. Add `DeviceDetective.ps1` to NinjaOne and run it as SYSTEM.
5. Add `DeviceDetective_AlertEvaluator.ps1` to the Script Result condition.
6. Validate Normal, Review Required, Prohibited Device, and Error behavior.
7. Confirm Current Devices and Alert Devices contain the intended records.
8. Test database refresh, validation, and tamper recovery.
9. Confirm `AlertEvaluator.last-result.txt` is created and updated.
10. Validate Zendesk creation, duplicate suppression, reset, and retrigger behavior.
11. Deploy through the Windows Workstation Policy.
12. Run Device Detective hourly, 24 hours a day.
13. Continue observing reboot and patch cycles for the 60-minute safeguard.

## Security considerations

- Do not store credentials, tokens, endpoint inventories, usernames, or confidential data in the public repository.
- Limit the public database to hardware identifiers, friendly names, classifications, and non-sensitive notes.
- Keep Zendesk credentials and direct ticketing logic out of the scripts.
- Treat VID/PID approval as model-wide rather than unit-specific.
- Device Detective supports monitoring and technician review; it is not a complete device-control or data-loss-prevention system.

## Known limitations and open work

- Some hardware does not expose reliable VID/PID.
- Composite hardware may expose multiple Windows interfaces.
- Bluetooth reporting varies by hardware and driver.
- VID/PID normally identifies a model, not an individual physical unit.
- HID-class monitoring can include headsets and other HID-capable hardware.
- Windows may expose stale paired Bluetooth devices as present.
- Instantaneous Bluetooth connection state cannot safely distinguish obsolete pairings from sleeping devices.
- Unexplained VHF records remain visible unless parent tracing proves duplication.
- NinjaOne collapses Alert Evaluator line breaks before passing output to Zendesk.
- Reset entries can be visually confusing even though they append correctly.
- Missing expected keyboard/mouse reporting requires a separate expectation model and is not implemented.
- Unknown-device baseline approval is not yet blocked in code despite the documented technician rule.
- The 60-minute post-reboot field safeguard remains under observation.
- Release versioning and a formal changelog have not yet been added.

## License

No license has currently been assigned to this project.
