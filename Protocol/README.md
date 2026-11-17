# Vendor protocol registry

These files are copied verbatim from the firmware repository
(`WeebLabs/DSPi`, `Documentation/protocol/`). They are the source of truth
for every vendor command the Console sends.

- `dspi_commands.json` lists every page and command of the paged protocol.
  `Tools/VendorProtocol/gen-vendor-commands.swift` turns it into
  `DSPi Console/VendorCommands.swift`.
- `legacy_map.json` maps each 1.1.6 opcode to its 1.1.7 command, and carries
  the result-code to `PIN_CONFIG_*` status mapping.

Copied from firmware commit `4b0db4e` on `release/v1.1.7`. A release must
replace both files with the copies from the firmware tag whose UF2 images it
bundles, then regenerate:

```
swift Tools/VendorProtocol/gen-vendor-commands.swift
```

Never edit these files or the generated Swift by hand. `VendorCommandsTests`
fails when the generated file and the registry disagree.
