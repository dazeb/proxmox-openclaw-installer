#!/bin/bash
# ==============================================================================
# 🦞 OpenClaw Appliance: "Remote Access" Edition 🦞
# ==============================================================================
# Features:
# 1. Installs Tailscale automatically.
# 2. First-Login Wizard forces a Tailscale connection (Secure Remote IP).
# 3. Live Install Logs (No freezing).
# 4. Standard VGA Display & Robust IP detection.
# ==============================================================================

set -e

# --- 0. Testing Mode Setup ---
# Set TEST_MODE=true to bypass whiptail and use defaults
: "${TEST_MODE:=false}"

# --- 1. Cleanup Trap ---
cleanup() {
    # Only cleanup if we failed or were interrupted before completion
    if [ "$?" -ne 0 ]; then
        echo ">>> Error occurred. Cleaning up..."
    fi
}
trap cleanup EXIT

# --- 2. Host Dependency Check ---
if ! command -v whiptail &> /dev/null; then
    echo "Installing required UI tools..."
    apt-get update -qq && apt-get install -y whiptail -qq
fi

# --- 3. Interactive Configuration ---
function msg_error() { whiptail --title "Error" --msgbox "$1" 10 60; exit 1; }

# Get Next Free VMID
NEXTID=$(pvesh get /cluster/nextid)
if [ "$TEST_MODE" = "true" ]; then
    VMID="$NEXTID"
    VMNAME="OpenClaw-Test"
    echo ">>> TEST_MODE: Using VMID=$VMID, VMNAME=$VMNAME"
else
    while true; do
        VMID=$(whiptail --inputbox "Set Virtual Machine ID" 8 78 "$NEXTID" --title "OpenClaw Setup" 3>&1 1>&2 2>&3) || exit 0
        if [ -z "$VMID" ]; then continue; fi
        if qm status "$VMID" &>/dev/null; then
            whiptail --title "Error" --msgbox "VMID $VMID is already in use!" 10 60
            continue
        fi
        break
    done

    # Get VM Name
    VMNAME=$(whiptail --inputbox "Set VM Name" 8 78 "OpenClaw-AI" --title "OpenClaw Setup" 3>&1 1>&2 2>&3) || exit 0
    if [ -z "$VMNAME" ]; then VMNAME="OpenClaw-AI"; fi
fi

# Storage Selection
RAW_STORAGE=$(pvesm status -content images | awk 'NR>1 && $3=="active" {print $1 " " $2}')
if [ -z "$RAW_STORAGE" ]; then 
    msg_error "CRITICAL: No active storage pools with 'images' content type found!"
fi

if [ "$TEST_MODE" = "true" ]; then
    STORAGE="local-zfs"
    echo ">>> TEST_MODE: Using Storage=$STORAGE"
else
    MENU_ARGS=()
    while read -r s t; do MENU_ARGS+=("$s" "$t"); done <<< "$RAW_STORAGE"
    STORAGE=$(whiptail --menu "Select Storage Pool (for VM Disk)" 15 60 4 "${MENU_ARGS[@]}" 3>&1 1>&2 2>&3) || exit 0
fi

# Snippet Storage Selection
RAW_SNIPPET_STORAGE=$(pvesm status -content snippets | awk 'NR>1 && $3=="active" {print $1 " " $2}')
if [ -z "$RAW_SNIPPET_STORAGE" ]; then
    msg_error "CRITICAL: No active storage pools with 'snippets' content type found! Please enable 'snippets' on at least one directory-based storage."
fi

if [ "$TEST_MODE" = "true" ]; then
    if echo "$RAW_SNIPPET_STORAGE" | grep -q "^local-hdd "; then
        SNIPPET_STORAGE="local-hdd"
    else
        SNIPPET_STORAGE=$(echo "$RAW_SNIPPET_STORAGE" | awk 'NR==1 {print $1}')
    fi
    echo ">>> TEST_MODE: Using Snippet Storage=$SNIPPET_STORAGE"
else
    MENU_ARGS_SNIPPETS=()
    while read -r s t; do MENU_ARGS_SNIPPETS+=("$s" "$t"); done <<< "$RAW_SNIPPET_STORAGE"
    SNIPPET_STORAGE=$(whiptail --menu "Select Snippet Storage Pool" 15 60 4 "${MENU_ARGS_SNIPPETS[@]}" 3>&1 1>&2 2>&3) || exit 0
fi

# ISO Storage Selection
RAW_ISO_STORAGE=$(pvesm status -content iso | awk 'NR>1 && $3=="active" {print $1 " " $2}')
if [ -z "$RAW_ISO_STORAGE" ]; then
    ISO_BASE_PATH="/tmp"
else
    ISO_STORE_NAME=$(echo "$RAW_ISO_STORAGE" | awk 'NR==1 {print $1}')
    ISO_BASE_PATH=$(pvesh get "/storage/$ISO_STORE_NAME" --output-format yaml | awk '/^path:/ {print $2}')
fi

# --- 4. Tailscale Auth Key (Optional) ---
if [ "$TEST_MODE" = "true" ]; then
    TS_AUTHKEY=""
else
    TS_AUTHKEY=$(whiptail --inputbox "Enter Tailscale Auth Key (Optional - leave blank for manual login)" 10 78 "" --title "Tailscale Setup" 3>&1 1>&2 2>&3) || exit 0
fi

# --- 5. Image Acquisition ---
UBUNTU_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMAGE_NAME="ubuntu-2404-cloud.img"

if [ -d "$ISO_BASE_PATH/template/iso" ]; then
    ISO_PATH="$ISO_BASE_PATH/template/iso"
else
    ISO_PATH="$ISO_BASE_PATH"
fi

echo ">>> [1/6] Verifying Source Image..."
if [ ! -f "$ISO_PATH/$IMAGE_NAME" ]; then
    wget -q --show-progress -O "$ISO_PATH/$IMAGE_NAME" "$UBUNTU_URL"
fi

# --- 6. Cloud-Init Configuration ---
SNIPPET_BASE_PATH=$(pvesh get "/storage/$SNIPPET_STORAGE" --output-format yaml | awk '/^path:/ {print $2}')
SNIPPET_DIR="$SNIPPET_BASE_PATH/snippets"
mkdir -p "$SNIPPET_DIR"
SNIPPET_FILE="$SNIPPET_DIR/openclaw-v$VMID.yaml"

echo ">>> [2/6] Generating Cloud-Init Configuration..."
cat <<EOF > "$SNIPPET_FILE"
#cloud-config
hostname: $VMNAME
manage_etc_hosts: true
ssh_pwauth: true
locale: en_US.UTF-8
timezone: UTC

users:
  - name: openclaw
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    plain_text_passwd: 'changeme'
    lock_passwd: false
    groups: [sudo, docker, adm] 

package_update: true
package_upgrade: true
packages:
  - curl
  - git
  - build-essential
  - qemu-guest-agent
  - unzip
  - ca-certificates
  - gnupg
  - libcairo2-dev
  - libpango1.0-dev
  - libjpeg-dev
  - libgif-dev
  - librsvg2-dev
  - libgbm1
  - libasound2
  - libnss3
  - libxss1
  - libatk-bridge2.0-0
  - libgtk-3-0
  - lsb-release
  - locales
  - needrestart

write_files:
  - path: /etc/needrestart/needrestart.conf
    content: |
      \$nrconf{restart} = 'a';
      \$nrconf{kernelhints} = 0;

runcmd:
  - echo ">>> STARTING OPENCLAW INSTALLATION"
  - export DEBIAN_FRONTEND=noninteractive
  - locale-gen en_US.UTF-8
  - update-locale LANG=en_US.UTF-8
  
  # --- 1. Enable Serial Console for xterm.js ---
  - echo ">>> Configuring Serial Console..."
  - sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*/& console=tty0 console=ttyS0,115200/' /etc/default/grub
  - grep -q "GRUB_TERMINAL" /etc/default/grub || echo 'GRUB_TERMINAL="console serial"' >> /etc/default/grub
  - grep -q "GRUB_SERIAL_COMMAND" /etc/default/grub || echo 'GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"' >> /etc/default/grub
  - update-grub

  # --- 2. System Services (Agent First) ---
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent

  # --- 3. Install Docker ---
  - echo ">>> Installing Docker..."
  - curl -fsSL https://get.docker.com | sh
  - mkdir -p /home/openclaw/.docker/cli-plugins
  - echo ">>> Installing Docker Compose..."
  - curl -sSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o /home/openclaw/.docker/cli-plugins/docker-compose
  - chmod +x /home/openclaw/.docker/cli-plugins/docker-compose
  - chown -R openclaw:openclaw /home/openclaw/.docker

  # --- 4. Install Tailscale ---
  - echo ">>> Installing Tailscale..."
  - curl -fsSL https://tailscale.com/install.sh | sh
EOF

if [ ! -z "$TS_AUTHKEY" ]; then
cat <<EOF >> "$SNIPPET_FILE"
  - tailscale up --authkey $TS_AUTHKEY
EOF
fi

cat <<EOF >> "$SNIPPET_FILE"
  # --- 5. Install Node 22 ---
  - echo ">>> Installing Node 22..."
  - curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  - echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
  - apt-get update
  - apt-get install -y nodejs

  # --- 6. Install OpenClaw ---
  - echo ">>> Installing OpenClaw..."
  - mkdir -p /home/openclaw/.npm-global
  - chown -R openclaw:openclaw /home/openclaw/.npm-global
  - su - openclaw -c "npm config set prefix '/home/openclaw/.npm-global'"
  - su - openclaw -c "npm install -g openclaw@latest"
  
  # --- 7. Setup OpenClaw Daemon ---
  - echo ">>> Starting OpenClaw Daemon..."
  - su - openclaw -c "/home/openclaw/.npm-global/bin/openclaw daemon start"
  
  # --- 8. Run OpenClaw Doctor (Auto-Repair) ---
  - echo ">>> Running OpenClaw Doctor..."
  - su - openclaw -c "/home/openclaw/.npm-global/bin/openclaw doctor --repair --yes"

  # --- 9. System Services ---
  - loginctl enable-linger openclaw

  # --- 9. Final Instructions ---
  - |
    cat <<'BASHRC' >> /home/openclaw/.bashrc
    export PATH=\$PATH:/home/openclaw/.npm-global/bin
    
    if [ ! -f ~/.openclaw_installed ]; then
        clear
        echo -e "\e[1;32m==================================================\e[0m"
        echo -e "\e[1;32m   🦞 OpenClaw AI Appliance Installed! 🦞\e[0m"
        echo -e "\e[1;32m==================================================\e[0m"
        echo ""
        echo -e "\e[1;33m⚠️  CRITICAL STEP FOR REMOTE ACCESS:\e[0m"
        echo "1. Close this Proxmox Console tab now."
        echo "2. Re-open Console using the \e[1;36mxterm.js\e[0m option."
        echo "3. Run: \e[1;36msudo tailscale up\e[0m"
        echo "4. Copy the link by highlighting it."
        echo ""
        
        # Check Tailscale
        if tailscale status &>/dev/null; then
            TS_IP=\$(tailscale ip -4 | head -n 1)
            echo -e "\e[1;32m✅ REMOTE ACCESS: http://\$TS_IP:18789\e[0m"
        fi
        
        LOC_IP=\$(hostname -I | awk '{print \$1}')
        echo -e "\e[1;32m✅ LOCAL ACCESS:  http://\$LOC_IP:18789\e[0m"
        echo ""
        echo -e "\e[1;32m==================================================\e[0m"
        touch ~/.openclaw_installed
    fi
    BASHRC

  - |
    # Send a broadcast message to all logged in users (and console)
    wall -n "
    🦞 OPENCLAW INSTALLATION COMPLETE!
    
    ⚠️ ACTION REQUIRED:
    1. CLOSE this console window.
    2. OPEN Console again using 'xterm.js' mode.
    3. Login and run 'sudo tailscale up' to connect.
    "
EOF

# --- 7. VM Creation ---
echo ">>> [3/6] Creating Virtual Machine (ID: $VMID)..."
qm create $VMID --name "$VMNAME" --memory 4096 --cores 2 --net0 virtio,bridge=vmbr0
qm importdisk $VMID "$ISO_PATH/$IMAGE_NAME" $STORAGE
qm set $VMID --scsihw virtio-scsi-pci --scsi0 $STORAGE:vm-$VMID-disk-0
qm set $VMID --boot c --bootdisk scsi0
qm set $VMID --ide2 $STORAGE:cloudinit
qm set $VMID --serial0 socket
qm resize $VMID scsi0 +20G

# --- 8. Hardware Optimizations ---
echo ">>> [4/6] Applying Hardware Optimizations..."
qm set $VMID --cpu host 
qm set $VMID --agent enabled=1 
qm set $VMID --vga serial0 
qm set $VMID --cicustom "user=$SNIPPET_STORAGE:snippets/openclaw-v$VMID.yaml"
qm set $VMID --ipconfig0 ip=dhcp
qm set $VMID --ciuser openclaw --cipassword "changeme"

# --- 9. Boot & Wait ---
echo ">>> [5/6] Booting VM..."
qm start $VMID
echo ">>> Waiting for QEMU Agent (Allocating IP)..."

ATTEMPTS=0
MAX_ATTEMPTS=100
VM_IP=""

while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    # Robust IP detection for PVE 9+ (handles varying spaces in JSON output)
    DETECTED_IP=$(qm guest cmd $VMID network-get-interfaces 2>/dev/null | awk '/ip-address/ && !/127.0.0.1/ {print $3}' | tr -d ',"' | grep -v ":" | head -n 1)
    if [[ ! -z "$DETECTED_IP" ]]; then
        VM_IP="$DETECTED_IP"
        echo -e "\n>>> Success! Local IP: $VM_IP"
        break
    fi
    echo -n "."
    sleep 3
    ATTEMPTS=$((ATTEMPTS+1))
done

if [ -z "$VM_IP" ]; then VM_IP="<CHECK_SUMMARY_TAB>"; fi

# --- 10. Notes Injection ---
echo ""
echo ">>> [6/6] Setting Dashboard Notes..."
NOTES=$(cat <<EOF
<div align='center'>
  <a href='https://openclaw.ai' target='_blank' rel='noopener noreferrer' style='text-decoration: none;'>
    <div style='font-size: 80px; line-height: 1;'>🦞</div>
  </a>
  <h2 style='font-size: 24px; margin: 10px 0; color: #ff6b6b;'>OpenClaw AI</h2>
  <p style='color: #b0b0b0; margin-bottom: 15px;'>Tailscale + Docker Appliance</p>
  <div style='background: rgba(255, 255, 255, 0.05); padding: 10px; border-radius: 5px; display: inline-block; margin-bottom: 15px; border: 1px solid rgba(255, 255, 255, 0.1);'>
    <span style='color: #888; font-size: 11px; letter-spacing: 1px;'>LOCAL DASHBOARD</span><br>
    <b style='font-size: 16px; color: #4caf50;'>http://$VM_IP:18789</b>
    <hr style='border: 0; border-top: 1px solid #444; margin: 8px 0;'>
    <span style='color: #888; font-size: 11px; letter-spacing: 1px;'>REMOTE DASHBOARD</span><br>
    <span style='font-size: 12px; color: #aaa;'>Login to Console to Connect</span>
  </div>
  <br>
  <span style='margin: 0 8px;'>
    <i class="fa fa-book fa-fw" style="color: #999;"></i>
    <a href='https://docs.openclaw.ai/' target='_blank' style='text-decoration: none; color: #4dabf7; font-weight: bold;'>Docs</a>
  </span>
  <span style='margin: 0 8px;'>
    <i class="fa fa-github fa-fw" style="color: #999;"></i>
    <a href='https://github.com/openclaw/openclaw' target='_blank' style='text-decoration: none; color: #4dabf7; font-weight: bold;'>GitHub</a>
  </span>
</div>
EOF
)
qm set $VMID --description "$NOTES"

# --- 11. Completion ---
clear
echo "========================================================"
echo " 🦞 OpenClaw Appliance Installed! 🦞"
echo "========================================================"
echo " Details:"
echo "   VM ID:    $VMID"
echo "   User:     openclaw"
echo "   Pass:     changeme"
echo "========================================================"
echo " NEXT STEPS (CRITICAL):"
echo " 1. Click 'Console' on the VM."
echo " 2. Log in."
if [ -z "$TS_AUTHKEY" ]; then
echo " 3. You will be asked to authenticate Tailscale."
else
echo " 3. Tailscale joined automatically via Auth Key."
fi
echo " 4. Once connected, the setup wizard will finish."
echo "========================================================"
