# REA on Windows: tool setup

This fork includes `scripts/setup-windows-tools.ps1`, which sets up every
external analysis tool that REA supports on Windows x64, builds this checkout,
and registers it with Claude Code.

## Run it

From the repository root, in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-windows-tools.ps1
```

| Option            | Effect                                                   |
| ----------------- | -------------------------------------------------------- |
| `-ToolsDir <dir>` | Where portable tools go (default `C:\Tools`)             |
| `-SkipRepoBuild`  | Skip submodules, `npm ci` and the builds                 |
| `-SkipClaude`     | Leave Claude Code's MCP registration and REA skill as-is |

Windows may ask for administrator approval while the winget installers run.
The script skips anything already installed, so it is safe to run again.
When it finishes, start a new Claude Code session.

Requirements: 64-bit Windows 10 or later, winget, local NTFS drives, and about
3 GB of free space. Node.js is updated to 24.22.1 if the installed version is
older than REA requires. Python and the .NET SDK are optional; their tools are
skipped with a warning when they are missing.

## What it installs

Portable downloads are pinned and checked against the SHA-256 published on
each project's GitHub release before they are unpacked.

| Purpose                        | Tool                         | Version | Source                         |
| ------------------------------ | ---------------------------- | ------- | ------------------------------ |
| Native EXE/DLL decompiling     | Ghidra                       | 12.1.4  | GitHub release, pinned         |
| Java for Ghidra, JADX, apktool | Temurin JDK                  | 21      | winget                         |
| .NET NativeAOT programs        | REA NativeAOT extension      | built   | `third_party/ghidra-nativeaot` |
| Android APK code               | jadx-headless-mcp            | 0.7.1   | GitHub release, pinned         |
| Android APK resources          | apktool                      | 3.0.3   | GitHub release, pinned         |
| Android devices and emulators  | adb (platform-tools)         | latest  | winget                         |
| Disassembly and binary info    | Rizin                        | 0.9.1   | GitHub release, pinned         |
| Disassembly                    | GNU objdump (WinLibs)        | latest  | winget                         |
| Rizin GUI with REA bridge      | Cutter + `rea_bridge.py`     | 2.5.0   | GitHub release, pinned         |
| WebAssembly                    | WABT                         | 1.0.42  | GitHub release, pinned         |
| Capture files                  | tshark, capinfos (Wireshark) | latest  | winget                         |
| .NET decompiling               | ilspycmd                     | latest  | `dotnet tool`                  |
| Runtime hooking, ESP32 images  | frida-tools, esptool         | latest  | `pip --user`                   |

The script also:

- checks out four submodules (`binwalk`, `ghidra-nativeaot`,
  `jadx-headless-mcp`, `wakaru`), then runs `npm ci` and `npm run build:cached`;
- copies `native/windows/build/` from the published `rea-agents` npm package of
  the same version, because those Windows native controls can only be built on
  Linux (the folder is ignored by Git);
- sets these user environment variables: `GHIDRA_INSTALL_DIR`, `JAVA_HOME`,
  `REA_ADB_PATH`, `REA_APKTOOL_COMMAND`, `REA_JADX_MCP_JAR`,
  `REA_RIZIN_COMMAND`, `REA_OBJDUMP_COMMAND`, `REA_TSHARK_COMMAND`,
  `REA_CAPINFOS_COMMAND`, `REA_WABT_BIN_DIRECTORY`, `REA_ILSPY_CMD_PATH`,
  `REA_GHIDRA_NATIVEAOT_JAR` and `REA_BROWSER_EXECUTABLE`;
- registers `node scripts/rea.mjs mcp` from this checkout as the user-scoped
  `rea` MCP server in Claude Code, with the same variables, and updates the
  installed REA skill to match this checkout.

## Not available on Windows

REA runs external tools as owned processes with memory limits and full
process-tree cleanup. On Linux it uses `prlimit`, `ps` and `/proc`; on Windows
it uses Job Objects through `native/windows`, which REA has only wired up and
verified for some providers. REA refuses the following on Windows:

| Feature                             | Reason                                                                            |
| ----------------------------------- | --------------------------------------------------------------------------------- |
| Kuna provider                       | Windows process-tree ownership for Kuna is not verified                           |
| Firmware (binwalk, unblob)          | Unblob is Linux/macOS only; firmware holds names and file types NTFS cannot store |
| Live packet capture, sigrok         | Depend on Linux kernel resource limits                                            |
| Persistent gdb/Rizin debug sessions | Need a Linux TTY and `/proc`                                                      |
| Wakaru, pwntools, EVM               | Only verified on Linux x64                                                        |

IDA and JEB are commercial and need your own licence. Hopper has no Windows
release. To use the Linux-only features, run REA inside WSL.

## Check the setup

```powershell
node scripts\rea.mjs doctor --provider ghidra --provider jadx
claude mcp get rea
```

Quick tool checks against a copy of a Windows program:

```powershell
node scripts\rea.mjs analyze C:\path\to\copy\program.exe --provider ghidra
node scripts\rea.mjs execute-rizin-command C:\path\to\copy\program.exe "iI"
node scripts\rea.mjs inspect-with-objdump C:\path\to\copy\program.exe file_headers
node scripts\rea.mjs inspect-pcap-client
node scripts\rea.mjs list-frida-devices
```

## Undo

- Remove the MCP entry: `claude mcp remove rea -s user`, or switch back to the
  npm release with `npx rea-agents setup --client claude_code --yes`.
- Delete the user environment variables listed above.
- Delete the tool folders under `C:\Tools` and uninstall the winget packages
  (`winget uninstall --id <id>`).
