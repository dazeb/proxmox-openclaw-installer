# Proxmox OpenClaw Installer 🦞

An automated installer for deploying a fully-configured **OpenClaw AI Appliance** on Proxmox VE. This script handles everything from VM creation to secure remote access setup, giving you a private AI instance in minutes.

## Overview

The `install_openclaw.sh` script automates the deployment of a specialized Ubuntu 24.04 VM tailored for running [OpenClaw](https://openclaw.ai). It simplifies the complex setup of Docker, Node.js, and secure networking into a single interactive command.

## Key Features

- **Automated VM Provisioning:** Creates a Proxmox VM using the latest Ubuntu 24.04 Noble Cloud Image.
- **Tailscale Integration:** Built-in support for secure remote access. Use an optional Auth Key for zero-touch networking.
- **Optimized for AI:** Pre-installs Docker, Docker Compose, and Node.js 22.
- **One-Click Daemon:** OpenClaw is installed and configured as a background daemon automatically.
- **Interactive UI:** User-friendly `whiptail` interface for selecting VM IDs, names, and storage pools.
- **Dashboard Integration:** Automatically populates the Proxmox VM "Notes" section with a formatted HTML dashboard and access links.

## Prerequisites

- **Proxmox VE Host:** A working Proxmox environment.
- **Snippet Storage:** At least one storage pool must have the `snippets` content type enabled (required for Cloud-Init configuration).
- **Network Access:** The Proxmox host needs internet access to download the Ubuntu image and packages.

## Installation

Run the following command on your Proxmox host's shell:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/dazeb/proxmox-openclaw-installer/main/install_openclaw.sh)"
```

### Steps:
1.  **VM Configuration:** Choose a VM ID and Name.
2.  **Storage:** Select the storage pool for the disk and the snippets.
3.  **Tailscale (Optional):** Provide an Auth Key if you want automatic remote access setup.
4.  **Deployment:** Wait for the VM to be created and the Cloud-Init process to finish.

## Post-Installation

Once the script completes:

1.  Navigate to the VM in Proxmox and click on **Console**.
2.  Log in with:
    - **User:** `openclaw`
    - **Password:** `changeme` (It is highly recommended to change this immediately).
3.  If you didn't provide a Tailscale Auth Key, run `sudo tailscale up` to connect your instance to your tailnet.
4.  Access your OpenClaw dashboard at the IP provided in the Proxmox "Notes" tab or displayed in the terminal.

## Under the Hood

- **Guest Agent:** Automatically enabled for IP reporting and seamless management.
- **Serial Console:** Configured to use `serial0` (xterm.js) for high-performance terminal access in the browser.
- **Auto-Repair:** Runs `openclaw doctor` on first boot to ensure all dependencies are correctly initialized.

## Development & Testing

You can bypass the interactive menus for testing purposes by setting `TEST_MODE=true`:

```bash
export TEST_MODE=true
./install_openclaw.sh
```

---

*Built with passion for the AI community.* 🦞
