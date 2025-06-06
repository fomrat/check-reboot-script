#!/bin/sh
# Set terminal colors (optional)
RED=""; GREEN=""; YELLOW=""; RESET=""; BOLD=""
if [ -t 1 ]; then
  RED=$(printf '\033[0;31m')
  GREEN=$(printf '\033[0;32m')
  YELLOW=$(printf '\033[0;33m')
  RESET=$(printf '\033[0m')
  BOLD=$(printf '\033[1m')
fi
REBOOT_NEEDED=0

# ── Check for failed systemd services ────────────────────────────
if command -v systemctl >/dev/null 2>&1; then
  failed_services=$(systemctl --failed --no-legend --no-pager 2>/dev/null | awk '{print $1}' | grep -v '^$')
  if [ -n "$failed_services" ]; then
    echo
    echo "${RED}${BOLD}⚠️  Failed systemd services detected:${RESET}"
    echo "$failed_services" | while read -r service; do
      echo "  ${RED}✗${RESET} $service"
    done
    echo
    echo "${YELLOW}💡 Check with: systemctl status <service-name>${RESET}"
    
    # Check for critical services that should trigger reboot
    critical_services="dbus dbus-broker NetworkManager systemd-logind gdm lightdm sddm"
    for critical in $critical_services; do
      if echo "$failed_services" | grep -q "^${critical}"; then
        echo "${RED}${BOLD}🚨 Critical service '${critical}' has failed - reboot strongly recommended!${RESET}"
        REBOOT_NEEDED=1
        break
      fi
    done
  else
    echo "${GREEN}✔ No failed systemd services.${RESET}"
  fi
else
  echo "${YELLOW}WARNING:${RESET} 'systemctl' not available — skipping failed services check."
fi

# ── Check for deleted shared libraries ─────────────────────────────
if command -v lsof >/dev/null 2>&1; then
  # Enhanced filtering for common false positives across distros
  deleted_libs=$(lsof -nP 2>/dev/null | grep -i 'deleted' | grep -vE 'pipewire|memfd:|gnome-she.*\(deleted\)|systemd.*\(deleted\)|dbus.*\(deleted\)' | awk '{ print $1 ": " $NF }' | sort -u)
  if [ -n "$deleted_libs" ]; then
    echo
    echo "${RED}${BOLD}⚠️  Deleted libraries are still in use:${RESET}"
    echo "$deleted_libs"
    REBOOT_NEEDED=1
  else
    echo "${GREEN}✔ No deleted libraries detected.${RESET}"
  fi
else
  echo "${YELLOW}WARNING:${RESET} 'lsof' not installed — skipping deleted library check."
fi

# ── Check for newer kernel installed ──────────────────────────────
CURRENT_KERNEL=$(uname -r)

# Function to find boot directory (handles different distros)
find_boot_dir() {
  if [ -d /boot ]; then
    echo "/boot"
  elif [ -d /boot/efi ]; then
    echo "/boot/efi"
  else
    echo ""
  fi
}

# Function to check if kernel files exist for a given module directory
kernel_files_exist() {
  local module_dir="$1"
  local boot_dir="$2"
  
  # Standard naming (Fedora, Ubuntu, etc.)
  if [ -f "$boot_dir/vmlinuz-$module_dir" ] || \
     [ -f "$boot_dir/kernel-$module_dir" ] || \
     [ -f "$boot_dir/Image-$module_dir" ] || \
     [ -f "$boot_dir/zImage-$module_dir" ]; then
    return 0
  fi
  
  # Arch Linux style - generic kernel file name
  if [ -f "$boot_dir/vmlinuz-linux" ] || \
     [ -f "$boot_dir/Image" ]; then
    return 0
  fi
  
  return 1
}

if [ -d /lib/modules ]; then
  BOOT_DIR=$(find_boot_dir)
  
  if [ -n "$BOOT_DIR" ]; then
    # Only consider kernels that actually exist in boot directory
    NEWEST_KERNEL=""
    for module_dir in $(ls -1 /lib/modules | sort -V); do
      if kernel_files_exist "$module_dir" "$BOOT_DIR"; then
        NEWEST_KERNEL="$module_dir"
      fi
    done
    
    if [ -n "$NEWEST_KERNEL" ] && [ "$CURRENT_KERNEL" != "$NEWEST_KERNEL" ]; then
      echo
      echo "${RED}${BOLD}⚠️  Newer kernel installed (${NEWEST_KERNEL}) but not running (${CURRENT_KERNEL})${RESET}"
      REBOOT_NEEDED=1
    else
      echo "${GREEN}✔ Running the latest kernel ($CURRENT_KERNEL).${RESET}"
    fi
  else
    # Fallback to original method if boot directory structure is unusual
    NEWEST_KERNEL=$(ls -1 /lib/modules | sort -V | tail -n 1)
    if [ "$CURRENT_KERNEL" != "$NEWEST_KERNEL" ]; then
      echo
      echo "${YELLOW}⚠️  Newer kernel modules found (${NEWEST_KERNEL}) but not running (${CURRENT_KERNEL})${RESET}"
      echo "${YELLOW}    Note: Could not verify kernel files in boot directory${RESET}"
      REBOOT_NEEDED=1
    else
      echo "${GREEN}✔ Running the latest kernel ($CURRENT_KERNEL).${RESET}"
    fi
  fi
else
  echo "${YELLOW}WARNING:${RESET} Could not determine installed kernels (missing /lib/modules)"
fi

# ── Use optional system tools if available ────────────────────────
if command -v needrestart >/dev/null 2>&1; then
  echo
  echo "${YELLOW}ℹ Running 'needrestart' for additional checks...${RESET}"
  needrestart -r l
fi

if command -v checkrestart >/dev/null 2>&1; then
  echo
  echo "${YELLOW}ℹ Running 'checkrestart' for additional checks...${RESET}"
  checkrestart
fi

# ── Optional fast reboot via kexec ────────────────────────────────
if command -v kexec >/dev/null 2>&1 && [ "$REBOOT_NEEDED" -eq 1 ] && [ -n "$NEWEST_KERNEL" ]; then
  BOOT_DIR=$(find_boot_dir)
  if [ -n "$BOOT_DIR" ]; then
    echo
    echo "${YELLOW}⚡ 'kexec' is installed. You can perform a fast reboot without full hardware reset.${RESET}"
    
    # Try to find the correct kernel and initrd files
    KERNEL_FILE=""
    INITRD_FILE=""
    
    for kernel_name in "vmlinuz-$NEWEST_KERNEL" "kernel-$NEWEST_KERNEL" "Image-$NEWEST_KERNEL" "zImage-$NEWEST_KERNEL"; do
      if [ -f "$BOOT_DIR/$kernel_name" ]; then
        KERNEL_FILE="$BOOT_DIR/$kernel_name"
        break
      fi
    done
    
    for initrd_name in "initrd.img-$NEWEST_KERNEL" "initramfs-$NEWEST_KERNEL.img" "initrd-$NEWEST_KERNEL" "initrd-$NEWEST_KERNEL.img"; do
      if [ -f "$BOOT_DIR/$initrd_name" ]; then
        INITRD_FILE="$BOOT_DIR/$initrd_name"
        break
      fi
    done
    
    if [ -n "$KERNEL_FILE" ] && [ -n "$INITRD_FILE" ]; then
      echo "  Example: sudo kexec -l $KERNEL_FILE --initrd=$INITRD_FILE --reuse-cmdline"
      echo "           sudo systemctl kexec"
    else
      echo "  Could not locate kernel/initrd files for kexec"
    fi
  fi
fi

# ── Final summary ─────────────────────────────────────────────────
if [ "$REBOOT_NEEDED" -eq 1 ]; then
  echo
  echo "${RED}${BOLD}🔁 Reboot is recommended to apply all updates.${RESET}"
  exit 1
else
  echo
  echo "${GREEN}✅ No reboot needed.${RESET}"
  exit 0
fi
