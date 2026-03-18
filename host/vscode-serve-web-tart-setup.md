# VSCode serve-web Setup: Tart macOS VM to Host Browser

## Overview

This guide covers how to run `code serve-web` in a Tart macOS VM and access it from a browser on the host machine, including workarounds for extension installation issues.

## The Problem

Extensions fail to install with "Error while fetching extensions resource list Forbidden" (403 error). This is a **CORS (Cross-Origin Resource Sharing) issue** - even when accessing via localhost through SSH tunneling, the browser's requests to the VS Code marketplace are being blocked due to origin header restrictions.

This is a [known limitation](https://github.com/microsoft/vscode-remote-release/issues/6924) with `code serve-web` when running in a browser context.

---

## Recommended Solution: Install Extensions via CLI

Since the browser-based extension marketplace has CORS issues, install extensions using the command line instead.

### Step 1: Start serve-web in the VM

```bash
code serve-web --host 0.0.0.0 --port 18000 --accept-server-license-terms
```

### Step 2: Set up SSH port forwarding (for browser access)

On the **host machine**:
```bash
ssh -L 18000:localhost:18000 admin@$(tart ip <your-vm-name>)
```

### Step 3: Install extensions via CLI (inside the VM)

In a separate terminal in the VM, install extensions using:
```bash
code ext install <extension-id>
```

Examples:
```bash
code ext install ms-python.python
code ext install ms-vscode.cpptools
code ext install esbenp.prettier-vscode
```

Find extension IDs on the [VS Code Marketplace](https://marketplace.visualstudio.com/vscode) - they're shown on each extension's page.

### Step 4: Reload in browser

After installing extensions via CLI:
1. Open `http://localhost:18000` in your host browser
2. Run "Reload Window" from the Command Palette (Cmd+Shift+P or F1)
3. Extensions should now appear and be active

---

## Alternative: Manual VSIX Installation

If CLI install doesn't work:

1. Download the `.vsix` file from the [VS Code Marketplace](https://marketplace.visualstudio.com/vscode)
   - Click on an extension → "Download Extension" link on the right side
   - **Important**: Rename the file from `.VSIXPackage` to `.vsix` (lowercase)

2. In the browser VS Code:
   - Open Command Palette (Cmd+Shift+P)
   - Run "Extensions: Install from VSIX..."
   - Select the downloaded `.vsix` file

---

## Alternative: Use VS Code Remote-SSH Instead

If you need full extension support, consider using VS Code's built-in Remote-SSH feature instead of serve-web:

1. Install VS Code on your **host machine** (not in the VM)
2. Install the "Remote - SSH" extension
3. Connect to the VM via SSH:
   - Command Palette → "Remote-SSH: Connect to Host..."
   - Enter: `admin@<vm-ip>` (get IP with `tart ip <vm-name>`)

This gives you the full VS Code desktop experience with all extensions working normally.

---

## Basic Setup (Without Extension Installation)

If you only need basic editing without extensions:

### From VM directly
```bash
code serve-web --port 18000
# Access at http://localhost:18000 inside the VM browser
```

### From host via SSH tunnel
```bash
# In VM:
code serve-web --host 0.0.0.0 --port 18000

# On host:
ssh -L 18000:localhost:18000 admin@$(tart ip <vm-name>)
# Access at http://localhost:18000 on host browser
```

---

## Summary

| Method | Extensions Work? | Complexity |
|--------|------------------|------------|
| serve-web + CLI extension install | Yes | Low |
| serve-web + VSIX manual install | Yes | Medium |
| VS Code Remote-SSH from host | Yes (full support) | Low |
| serve-web browser only | No | Lowest |

**Recommended**: Use `code ext install` via CLI to install extensions, then access via browser. If you need full extension marketplace browsing, use VS Code Remote-SSH instead.
