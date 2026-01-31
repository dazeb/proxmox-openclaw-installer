#!/bin/bash
# OpenClaw Appliance Setup Script
# This runs INSIDE the VM during the first boot.

set -e
export DEBIAN_FRONTEND=noninteractive

echo ">>> [1/7] Configuring Locales & Console..."
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# Enable Serial Console for Proxmox xterm.js
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*/& console=tty0 console=ttyS0,115200/' /etc/default/grub
grep -q "GRUB_TERMINAL" /etc/default/grub || echo 'GRUB_TERMINAL="console serial"' >> /etc/default/grub
grep -q "GRUB_SERIAL_COMMAND" /etc/default/grub || echo 'GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"' >> /etc/default/grub
update-grub

echo ">>> [2/7] Starting Guest Services..."
systemctl enable qemu-guest-agent
systemctl start qemu-guest-agent

echo ">>> [3/7] Installing Docker..."
curl -fsSL https://get.docker.com | sh
mkdir -p /home/openclaw/.docker/cli-plugins
curl -sSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o /home/openclaw/.docker/cli-plugins/docker-compose
chmod +x /home/openclaw/.docker/cli-plugins/docker-compose
chown -R openclaw:openclaw /home/openclaw/.docker

echo ">>> [4/7] Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
if [ -n "$TS_AUTHKEY" ]; then
    echo ">>> Authenticating Tailscale..."
    tailscale up --authkey "$TS_AUTHKEY"
fi

echo ">>> [5/7] Installing Node 22..."
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
apt-get update
apt-get install -y nodejs

echo ">>> [6/7] Installing OpenClaw..."
mkdir -p /home/openclaw/.npm-global
chown -R openclaw:openclaw /home/openclaw/.npm-global
su - openclaw -c "npm config set prefix '/home/openclaw/.npm-global'"
su - openclaw -c "npm install -g openclaw@latest"
su - openclaw -c "/home/openclaw/.npm-global/bin/openclaw daemon start"
su - openclaw -c "/home/openclaw/.npm-global/bin/openclaw doctor --repair --yes"

echo ">>> [7/7] Finalizing System..."
loginctl enable-linger openclaw

# Setup the welcome banner in .bashrc
cat <<'EOF' >> /home/openclaw/.bashrc
export PATH=$PATH:/home/openclaw/.npm-global/bin
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

if [ ! -f ~/.openclaw_installed ]; then
    clear
    echo -e "\033[1;32m==================================================\033[0m"
    echo -e "\033[1;32m   🦞 OpenClaw AI Appliance Installed! 🦞\033[0m"
    echo -e "\033[1;32m==================================================\033[0m"
    echo ""
    echo -e "\033[1;33m⚠️  CRITICAL STEP FOR REMOTE ACCESS:\033[0m"
    echo "1. Close this Proxmox Console tab now."
    echo "2. Re-open Console using the \033[1;36mxterm.js\033[0m option."
    echo "3. Run: \033[1;36msudo tailscale up\033[0m"
    echo "4. Copy the link by highlighting it."
    echo ""
    
    if tailscale status &>/dev/null; then
        TS_IP=$(tailscale ip -4 | head -n 1)
        echo -e "\033[1;32m✅ REMOTE ACCESS: http://$TS_IP:18789\033[0m"
    fi
    
    LOC_IP=$(hostname -I | awk '{print $1}')
    echo -e "\033[1;32m✅ LOCAL ACCESS:  http://$LOC_IP:18789\033[0m"
    echo ""
    echo -e "\033[1;32m==================================================\033[0m"
    touch ~/.openclaw_installed
fi
EOF

# Refresh the getty to show the login prompt immediately
(sleep 5 && systemctl restart serial-getty@ttyS0) &
echo ">>> INSTALLATION COMPLETE"
