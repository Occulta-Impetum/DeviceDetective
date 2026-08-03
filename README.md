# Device Detective Database

This repository contains the VID/PID friendly-name and classification database used by the Device Detective NinjaOne automation.

## Database file

`usbids.csv`

## Columns

- VendorID
- ProductID
- VendorName
- ProductName
- Classification
- Notes

## Valid classifications

- Approved
- Known
- Prohibited
- Ignored

Devices not found in the database are treated as Unknown by the script.
