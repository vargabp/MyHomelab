#!/bin/sh
#
# This will export the config off a OpenWRT device monthly onto an SMB share, on the first defined day of the week
# It will require cifs, which is not installed by default.
# This has been tested on OpenWRT v24.10 on a GL-Inet Flint 2
#
# Usage
# Download and make it executable:
#    DL_TO=~/backup-openwrt-to-smb.sh
#    URL=https://raw.githubusercontent.com/vargabp/MyHomelab/main/backup-openwrt-to-smb.sh
#    curl -o "$DL_TO" $URL && chmod +x "$DL_TO"
#
# After downloading, edit the Config section in the file to match your environment.
#
# Create and secure a file containing credentials relevant to the SMB server, you may use this "one"-liner:
#    f=~/.private/.smbhost.my.home && echo -e "username=nasuser\npassword=nasUserP@ss" > "$f" && chown $(id -u):$(id -g) "$f" && chmod 400 "$f"
#      change this ^^^^^^^^^^^^^^^             and this ^^^^^^^  this too ^^^^^^^^^^^
#
# Using the GUI [System] > [Scheduled Tasks] add this line (no indentation) to schedule it to run at 6AM each day:
#     0 6 * * * /root/backup-openwrt-to-smb.sh
#               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ this should point to the script 
# There are further controls inside the script to exit early unless it's the 1st Friday (configurable) of the month.

# Config --- make it your own
DAY_OF_WEEK_TO_RUN="Friday" # This will only run on the day of the week defined here. Must match 'date +%A' format (e.g. Monday, Friday, Sunday)
SMB_HOST="smbhost.my.home" # Remote host to backup to
SMB_SHARE="ConfigBackups/openwrt.my.home" # The path on the SMB_HOST where the backup will go.
BACKUPS_TO_KEEP=24 # script will delete from oldest until only this number of automated backups is left. Set to 0 or less to keep everything.
PRIVATE_FILE="$HOME/.private/.${SMB_HOST}" # If the structure in the one-liner was respected, there's no need to change this
# End of config

# Define a cleanup routine for any exit conditions 
CLEANUP_NEEDED=true
cleanup() {
    if [ "$CLEANUP_NEEDED" = true ] && grep -qs "$MOUNT_POINT " /proc/mounts; then
        if umount "$MOUNT_POINT"; then
            logger -t backup-to-smb "Unmounted $MOUNT_POINT"
            if rm -rf "$MOUNT_POINT"; then
                logger -t backup-to-smb "Force-removed $MOUNT_POINT"
            else
                logger -t backup-to-smb "ERROR: Failed to force-remove $MOUNT_POINT"
            fi
        else
            logger -t backup-to-smb "ERROR: Failed to unmount $MOUNT_POINT; directory left untouched to avoid accidental deletion of remote files"
        fi
    fi
}
trap cleanup EXIT INT TERM HUP

# We will check requirements before any further checks.
# This will flag these issues daily, not only on that one day a month.
REQUIRED_CMDS="mount.cifs umount sysupgrade"
for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        logger -t backup-to-smb "Requirement check failed: '$cmd' command not found"
        exit 1
    fi
# Check CIFS kernel module loaded
if ! grep -q cifs /proc/filesystems; then
    logger -t backup-to-smb "Requirement check failed: CIFS kernel module not available"
    exit 1
fi

# Only continue if today is the first $DAY_OF_WEEK_TO_RUN of the month
CURRENT_DAY_NAME=$(date +%A)
CURRENT_DAY_OF_MONTH=$(date +%d)

if [ "$CURRENT_DAY_NAME" = "$DAY_OF_WEEK_TO_RUN" ] && [ "$CURRENT_DAY_OF_MONTH" -le 7 ]; then
    logger -t backup-to-smb "Running backup: today is the first $DAY_OF_WEEK_TO_RUN of the month."
else
    logger -t backup-to-smb "Skipped backup: not the first $DAY_OF_WEEK_TO_RUN of the month."
    exit 0
fi

# Preparing the backup path...
MOUNT_POINT="/mnt/${SMB_HOST}-backup-to-smb" # Local path for the temp mount
HOSTNAME=$(uci get system.@system[0].hostname)
DATE=$(date +"%Y-%m-%d")
TIME=$(date +"%Y-%m-%d %H:%M:%S")
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
BACKUP_NAME="backup-${HOSTNAME}-${DATE}-auto.tar.gz"
BACKUP_PATH="${MOUNT_POINT}/${BACKUP_NAME}"
JOURNAL_PATH="${MOUNT_POINT}/Journal.txt"
MOUNT_OPTIONS="vers=3.0,credentials=$PRIVATE_FILE"

# Mount SMB share
if grep -qs "$MOUNT_POINT " /proc/mounts; then
    umount "$MOUNT_POINT"
    logger -t backup-to-smb "Pre-existing mount at $MOUNT_POINT unmounted"
fi

if [ ! -d "$MOUNT_POINT" ]; then
    mkdir -p "$MOUNT_POINT"
    logger -t backup-to-smb "Mount point did not exist. Created $MOUNT_POINT"
fi

if mount -t cifs "//$SMB_HOST/$SMB_SHARE" "$MOUNT_POINT" -o "$MOUNT_OPTIONS"; then
    logger -t backup-to-smb "Mounted successfully: //$SMB_HOST/$SMB_SHARE > $MOUNT_POINT"    
else
    logger -t backup-to-smb "Backup failed: could not mount //$SMB_HOST/$SMB_SHARE"
    exit 1
fi

# Check if the backup file already exists
if [ -f "$BACKUP_PATH" ]; then
    echo -e "${BACKUP_NAME}\tAttempted to create file but already existed at ${TIME}" >> "$JOURNAL_PATH"
    logger -t backup-to-smb "Skipped backup: $BACKUP_NAME already exists"
    exit 0
fi

# Create the backup
if sysupgrade -b "$BACKUP_PATH"; then
    logger -t backup-to-smb "Backup successful: $BACKUP_NAME"
    echo -e "${BACKUP_NAME}\tAutomatic monthly backup created by ${SCRIPT_PATH} at ${TIME}" >> "$JOURNAL_PATH"
else
    logger -t backup-to-smb "Backup failed: sysupgrade command error"
    echo -e "${BACKUP_NAME}\t[!] Automatic monthly backup likely failed: ${SCRIPT_PATH} at ${TIME}" >> "$JOURNAL_PATH"
    exit 1
fi

# Clean up

# Retain only a set number of most recent -auto backups based on date in filename, not file metadata (in case we copy them over, or modify elsewhere).
if [ "$BACKUPS_TO_KEEP" -le 0 ]; then
    logger -t backup-to-smb "BACKUPS_TO_KEEP set to $BACKUPS_TO_KEEP; no tidying up required."
else
    DELETE_LIST=$(ls "$MOUNT_POINT"/backup-${HOSTNAME}-*-auto.tar.gz 2>/dev/null | \
        sed -E "s|.*/backup-${HOSTNAME}-([0-9]{4}-[0-9]{2}-[0-9]{2})-auto.tar.gz|\1 &|" | \
        sort | \
        head -n -"$BACKUPS_TO_KEEP" | \
        cut -d' ' -f2-)
    # Process each file marked for deletion
    for FILEPATH in $DELETE_LIST; do
        FILENAME=$(basename "$FILEPATH")
    #    Before deleting, mark the historic journal line with [Auto-deleted].
        sed -i "/^${FILENAME}[[:space:]]/s/[[:space:]]*$/ [Auto-deleted]/" "$JOURNAL_PATH"
    #    Delete the backup file
        rm -f "$FILEPATH"
        logger -t backup-to-smb "Auto-deleted: $FILENAME"
    done
fi

exit 0
