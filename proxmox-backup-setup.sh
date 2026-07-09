#!/bin/bash

# Proxmox All-in-One USB Recovery Kit Setup
# Automates REAR (Host OS) and vzdump (Essential Guests) to USB

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD_CYAN='\033[1;36m'
BOLD_WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# Header drawing helper
show_header() {
  echo -e "${BOLD_CYAN}┌──────────────────────────────────────────────────────────┐${NC}"
  echo -e "${BOLD_CYAN}│${NC}          ${BOLD_WHITE}PROXMOX ALL-IN-ONE USB RECOVERY KIT             ${BOLD_CYAN}│${NC}"
  echo -e "${BOLD_CYAN}│${NC}                 ${GRAY}Interactive Setup Wizard                 ${BOLD_CYAN}│${NC}"
  echo -e "${BOLD_CYAN}└──────────────────────────────────────────────────────────┘${NC}"
}

# Step progress helper
print_step() {
  local num=$1
  local title=$2
  echo -e "\n${BOLD_CYAN}━❯ [${num}/4] ${title}${NC}"
  echo -e "${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Print header
show_header

# Check for root
if [ "$EUID" -ne 0 ]; then
  echo -e "\n${RED}Error: Please run as root (or use sudo).${NC}"
  exit 1
fi

# Dry-run check
DRY_RUN=false
if [[ "$1" == "--dry-run" ]]; then
  DRY_RUN=true
  echo -e "\n${YELLOW}⚠️  DRY RUN MODE ENABLED (No changes will be written)${NC}"
fi

# 1. Gather Info
print_step 1 "Gathering System Information & Disk Selection"

# Check for Proxmox
if [ ! -d "/etc/pve" ]; then
    echo -e "${RED}Error: Proxmox (PVE) not detected in /etc/pve.${NC}"
    echo -e "This script is intended to run directly on a Proxmox VE host."
    exit 1
fi

# Default to USB Mode (Network mode disabled for simplicity)
DEST_TYPE="2"

if [[ "$DEST_TYPE" == "1" ]]; then
    echo -en "${YELLOW}Enter Network Backup URL (e.g., nfs://192.168.1.100/backups): ${NC}"
    read BACKUP_URL
    OUTPUT_TYPE="ISO"
    BACKUP_TYPE="NETFS"
else
    # Gather physical block devices of type 'disk' (ignoring LVM and loop devices)
    mapfile -t DISK_LIST < <(lsblk -d -p -n -o NAME,SIZE,MODEL,TYPE | grep -i 'disk')
    
    if [ ${#DISK_LIST[@]} -eq 0 ]; then
        echo -e "${RED}Error: No physical disks found on the system!${NC}"
        exit 1
    fi

    echo -e "\n${BOLD_WHITE}Available Physical Disks:${NC}"
    for i in "${!DISK_LIST[@]}"; do
        # Parse fields to construct a clean table
        dev_name=$(echo "${DISK_LIST[$i]}" | awk '{print $1}')
        dev_size=$(echo "${DISK_LIST[$i]}" | awk '{print $2}')
        dev_model=$(echo "${DISK_LIST[$i]}" | awk '{$1=""; $2=""; $NF=""; print $0}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        printf "  ${BOLD_WHITE}%2d)${NC}  %-14s  %-8s  ${GRAY}%s${NC}\n" "$((i+1))" "$dev_name" "$dev_size" "$dev_model"
    done
    
    # Input validation loop for disk selection
    while true; do
        echo -en "\n${YELLOW}Select disk for recovery partition [1-${#DISK_LIST[@]}]: ${NC}"
        read DISK_IDX
        if [[ "$DISK_IDX" =~ ^[0-9]+$ ]] && [ "$DISK_IDX" -ge 1 ] && [ "$DISK_IDX" -le "${#DISK_LIST[@]}" ]; then
            break
        else
            echo -e "${RED}Invalid selection. Please choose a number from 1 to ${#DISK_LIST[@]}.${NC}"
        fi
    done

    USB_DEVICE=$(echo "${DISK_LIST[$((DISK_IDX-1))]}" | awk '{print $1}')
    
    # Formatting confirmation
    echo -e "\n${RED}⚠️  WARNING: Relax-and-Recover (ReaR) requires the USB drive to be formatted.${NC}"
    echo -e "${RED}   All existing data on $USB_DEVICE will be PERMANENTLY ERASED!${NC}"
    while true; do
        echo -en "${YELLOW}Are you sure you want to format $USB_DEVICE and label it 'REAR-000'? (y/N): ${NC}"
        read CONFIRM_FORMAT
        if [[ -z "$CONFIRM_FORMAT" || "$CONFIRM_FORMAT" =~ ^[nN] ]]; then
            echo -e "${YELLOW}Format cancelled. Continuing setup...${NC}"
            break
        elif [[ "$CONFIRM_FORMAT" =~ ^[yY] ]]; then
            if [ "$DRY_RUN" = false ]; then
                echo -e "${CYAN}Installing 'rear' package temporarily to run format...${NC}"
                apt-get update -qq || true
                apt-get install -y -qq rear
                echo -e "${CYAN}Formatting $USB_DEVICE (this may take a moment)...${NC}"
                rear format "$USB_DEVICE"
                echo -e "${GREEN}Format completed successfully!${NC}"
            else
                echo -e "${GRAY}[DRY-RUN] Would run: rear format $USB_DEVICE${NC}"
            fi
            break
        else
            echo -e "${RED}Please enter 'y' or 'n'.${NC}"
        fi
    done
    
    OUTPUT_TYPE="USB"
    BACKUP_TYPE="NETFS"
    BACKUP_URL="usb:///dev/disk/by-label/REAR-000"
fi

# Storage Selection Setup
if [[ "$DEST_TYPE" == "1" ]]; then
    # Network Mode Storage Selection
    echo -e "\n${BOLD_WHITE}Selecting Proxmox Backup Server (PBS) Storage${NC}"
    PBS_STORAGES=($(pvesm status -content backup | grep 'pbs' | awk '{print $1}'))

    if [ ${#PBS_STORAGES[@]} -eq 0 ]; then
        echo -e "${RED}No PBS type storage found! Guests will be backed up locally/manually if selected.${NC}"
        PBS_STORAGE=""
    elif [ ${#PBS_STORAGES[@]} -eq 1 ]; then
        PBS_STORAGE=${PBS_STORAGES[0]}
        echo -e "Automatically selected only available PBS storage: ${GREEN}$PBS_STORAGE${NC}"
    else
        echo "Multiple PBS storages found. Please select one for guest backups:"
        for i in "${!PBS_STORAGES[@]}"; do
            echo "$((i+1))) ${PBS_STORAGES[$i]}"
        done
        echo -en "${YELLOW}Selection [1-${#PBS_STORAGES[@]}]: ${NC}"
        read PBS_IDX
        PBS_STORAGE=${PBS_STORAGES[$((PBS_IDX-1))]}
    fi
else
    # USB Mode: Guests go directly onto the USB
    PBS_STORAGE="USB_DRIVE"
fi

# Gather Essential Guests (VMs/LXCs)
# Use python3 to parse JSON reliably (standard on PVE hosts)
mapfile -t GUEST_LIST < <(pvesh get /cluster/resources --type vm --output-format json | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    for g in sorted(data, key=lambda x: x.get("vmid", 0)):
        print(str(g.get("vmid", "?")) + " - " + str(g.get("name", "?")))
except Exception as e:
    pass
')

if [ ${#GUEST_LIST[@]} -eq 0 ]; then
    echo -e "\n${YELLOW}No VMs or Containers found on this cluster.${NC}"
    echo -en "${YELLOW}Enter VMID manually if known, or press Enter to skip: ${NC}"
    read GUEST_SELECTIONS
    ESSENTIAL_GUESTS="$GUEST_SELECTIONS"
else
    echo -e "\n${BOLD_WHITE}Available Guests (VMs/Containers):${NC}"
    for i in "${!GUEST_LIST[@]}"; do
        # Parse fields to construct a clean table
        vmid=$(echo "${GUEST_LIST[$i]}" | awk '{print $1}')
        name=$(echo "${GUEST_LIST[$i]}" | cut -d'-' -f2- | sed 's/^[[:space:]]*//')
        printf "  ${BOLD_WHITE}%2d)${NC}  ID: %-6s  Name: ${CYAN}%s${NC}\n" "$((i+1))" "$vmid" "$name"
    done

    # Validation loop for guest selections
    while true; do
        echo -e "\n${YELLOW}Which guests should be backed up?${NC}"
        echo -e "  - Enter list numbers separated by space (e.g. '1 3')"
        echo -e "  - Type 'all' to select all guests"
        echo -en "${YELLOW}Selection: ${NC}"
        read GUEST_SELECTIONS
        
        if [[ "$GUEST_SELECTIONS" == "all" ]]; then
            break
        fi
        
        if [[ -z "$GUEST_SELECTIONS" ]]; then
            echo -e "${RED}No guests selected. Please choose at least one or type 'all'.${NC}"
            continue
        fi
        
        VALID=true
        for idx in $GUEST_SELECTIONS; do
            if [[ ! "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#GUEST_LIST[@]}" ]; then
                VALID=false
                break
            fi
        done
        
        if [ "$VALID" = true ]; then
            break
        else
            echo -e "${RED}Invalid input: please enter valid numbers from the list above.${NC}"
        fi
    done

    ESSENTIAL_GUESTS=""
    if [[ "$GUEST_SELECTIONS" == "all" ]]; then
        for g in "${GUEST_LIST[@]}"; do
            ID=$(echo $g | awk '{print $1}')
            ESSENTIAL_GUESTS+="$ID "
        done
    else
        for idx in $GUEST_SELECTIONS; do
            ID=$(echo "${GUEST_LIST[$((idx-1))]}" | awk '{print $1}')
            ESSENTIAL_GUESTS+="$ID "
        done
    fi
fi

# Print final confirmation of selected guests
echo -e "\nSelected Guests to package: ${GREEN}${ESSENTIAL_GUESTS% }${NC}"

# 2. Install Dependencies
print_step 2 "Installing System Dependencies"
if [ "$DRY_RUN" = false ]; then
    echo -e "${CYAN}Updating package repositories...${NC}"
    apt-get update -qq || echo -e "${YELLOW}Warning: Repository update failed, attempting to proceed...${NC}"
    echo -e "${CYAN}Installing rear, genisoimage, nfs-common, and cifs-utils...${NC}"
    apt-get install -y -qq rear genisoimage nfs-common cifs-utils
    echo -e "${GREEN}Dependencies installed successfully!${NC}"
else
    echo -e "${GRAY}[DRY-RUN] Would run: apt-get install -y rear genisoimage nfs-common cifs-utils${NC}"
fi

# 3. Configure REAR
print_step 3 "Configuring Relax-and-Recover (ReaR)"

# Automatically find VM/LXC storage paths to exclude
EXCLUDES=( "/var/lib/vz/images/*" "/var/lib/vz/dump/*" "/var/lib/vz/template/*" )

if command -v zfs >/dev/null; then
    ZFS_POOLS=$(zfs list -H -o name,mountpoint | grep -v 'rpool' | awk '{print $2 "/*"}' || true)
    for p in $ZFS_POOLS; do
        EXCLUDES+=( "$p" )
    done
fi

EXCLUDE_STRING=$(printf "'%s' " "${EXCLUDES[@]}")

# Proxmox 9 / Debian 13 fixes for systemd and libraries
# We disable GRUB_RESCUE as it often fails on UEFI PVE nodes and isn't needed for USB recovery.
SYSTEMD_FIX="
# Library and Symlink Fixes
LD_LIBRARY_PATH+=\":/usr/lib/x86_64-linux-gnu/systemd\"
COPY_AS_IS+=( /usr/lib/x86_64-linux-gnu/systemd/libsystemd-shared-*.so /usr/share/file/magic /usr/share/misc/magic )
LIBS+=( /usr/lib/x86_64-linux-gnu/systemd/libsystemd-shared-257.so )
"

REAR_CONF="OUTPUT=$OUTPUT_TYPE
BACKUP=$BACKUP_TYPE
BACKUP_URL=$BACKUP_URL
BACKUP_PROG_EXCLUDE=( $EXCLUDE_STRING )
GRUB_RESCUE=0
$SYSTEMD_FIX"

if [ "$DRY_RUN" = false ]; then
    echo -e "$REAR_CONF" > /etc/rear/local.conf
    echo -e "Written configuration to: ${GREEN}/etc/rear/local.conf${NC}"
else
    echo -e "${YELLOW}[DRY-RUN] Proposed local.conf configuration:${NC}"
    echo -e "${GRAY}----------------------------------------${NC}"
    echo -e "$REAR_CONF"
    echo -e "${GRAY}----------------------------------------${NC}"
fi

# 4. Create the Sequential Backup Wrapper
print_step 4 "Creating Backup Command Wrapper"

if [[ "$DEST_TYPE" == "2" ]]; then
    # USB Wrapper
    WRAPPER_CONTENT="#!/bin/bash
set -e
echo '--- Starting REAR Host OS Backup (Verbose) ---'
rear -v mkbackup

echo '--- Starting Essential Guest Backups to USB Drive ---'
mkdir -p /mnt/rear_usb
mount /dev/disk/by-label/REAR-000 /mnt/rear_usb || { echo 'Failed to mount USB'; exit 1; }
mkdir -p /mnt/rear_usb/essential_guests

vzdump $ESSENTIAL_GUESTS --dumpdir /mnt/rear_usb/essential_guests --mode snapshot --compress zstd

umount /mnt/rear_usb
echo '--- All Backups Complete (Flash Drive is now your Total Recovery Kit) ---'
"
else
    # Network Wrapper
    WRAPPER_CONTENT="#!/bin/bash
set -e
echo '--- Starting REAR Host OS Backup (Verbose) ---'
rear -v mkbackup
echo '--- Starting Essential Guest Backups to $PBS_STORAGE ---'
vzdump $ESSENTIAL_GUESTS --storage $PBS_STORAGE --mode snapshot
echo '--- All Backups Complete ---'
"
fi

if [ "$DRY_RUN" = false ]; then
    echo "$WRAPPER_CONTENT" > /usr/local/bin/pve-strong-backup
    chmod +x /usr/local/bin/pve-strong-backup
    echo -e "Created custom script command: ${GREEN}/usr/local/bin/pve-strong-backup${NC}"
else
    echo -e "${YELLOW}[DRY-RUN] Proposed /usr/local/bin/pve-strong-backup script:${NC}"
    echo -e "${GRAY}----------------------------------------${NC}"
    echo "$WRAPPER_CONTENT"
    echo -e "${GRAY}----------------------------------------${NC}"
fi

# Setup Complete
echo -e "\n${GREEN}┌──────────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│                    SETUP COMPLETED!                      │${NC}"
echo -e "${GREEN}└──────────────────────────────────────────────────────────┘${NC}"
echo -e "\nYou can now run your full backup with one command:"
echo -e "  ${BOLD_CYAN}pve-strong-backup${NC}"
echo -e "\nThis wrapper will sequentially execute:"
echo -e "  ${BOLD_WHITE}1.${NC} Backup Proxmox Host OS to ${YELLOW}$USB_DEVICE${NC} (via REAR)"
if [[ "$DEST_TYPE" == "2" ]]; then
    echo -e "  ${BOLD_WHITE}2.${NC} Backup Essential Guests (${CYAN}${ESSENTIAL_GUESTS% }${NC}) directly to the ${YELLOW}same Flash Drive${NC}"
else
    echo -e "  ${BOLD_WHITE}2.${NC} Backup Essential Guests (${CYAN}${ESSENTIAL_GUESTS% }${NC}) to PBS storage: ${YELLOW}$PBS_STORAGE${NC}"
fi
echo -e "\n${GRAY}Enjoy your offline disaster recovery solution!${NC}"
