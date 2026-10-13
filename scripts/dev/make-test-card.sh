#!/bin/bash
# Builds a camera-card disk image with some files deleted, for trying the app without a real card.
#   scripts/dev/make-test-card.sh <folder> [exfat|formatted]
# "formatted" makes a FAT32 card, deletes nothing, then reformats it, so only the deep scan can find the photos.
set -euo pipefail
cd "$(dirname "$0")/../.."
WORK="${1:?folder}"
MODE="${2:-exfat}"
mkdir -p "$WORK"
PHOTOS="$WORK/photos"
rm -rf "$PHOTOS"
swift scripts/dev/make-photos.swift "$PHOTOS" 24 Canon "Canon EOS R6" >/dev/null
IMAGE="$WORK/card-$MODE.dmg"
rm -f "$IMAGE"
FS=ExFAT; [[ "$MODE" == formatted ]] && FS=FAT32
hdiutil create -size 512m -fs "$FS" -volname EOS_DIGITAL -layout MBRSPUD -type UDIF "$IMAGE" >/dev/null
DEV=$(hdiutil attach "$IMAGE" | awk '/\/Volumes\//{print $1; exit}')
DISK=$(echo "$DEV" | sed -E 's|/dev/(disk[0-9]+).*|\1|')
VOL=$(mount | awk -v d="$DEV" '$1==d{print $3; exit}')
mkdir -p "$VOL/DCIM/100CANON"
cp "$PHOTOS"/*.JPG "$VOL/DCIM/100CANON/"
cp "/System/Library/Wallpapers/.default/Golden Gate.mov" "$VOL/DCIM/100CANON/MVI_0025.MOV"
printf 'Shot list\n\n1. Ceremony\n2. Portraits\n3. Speeches\n' > "$WORK/notes.txt"
/usr/sbin/cupsfilter "$WORK/notes.txt" > "$VOL/Shot list.pdf" 2>/dev/null || true
sync
if [[ "$MODE" == formatted ]]; then
  hdiutil detach "$DEV" -quiet
  DEV=$(hdiutil attach -nomount "$IMAGE" | awk 'NR==1{print $1}')
  newfs_msdos -F 32 -v EOS_DIGITAL "${DEV}s1" >/dev/null 2>&1
else
  rm "$VOL"/DCIM/100CANON/IMG_000{3,4,5,6,7,8,9}.JPG "$VOL"/DCIM/100CANON/IMG_0010.JPG "$VOL/DCIM/100CANON/MVI_0025.MOV" "$VOL/Shot list.pdf"
  sync
fi
hdiutil detach "/dev/$DISK" -quiet || hdiutil detach "/dev/$DISK" -force -quiet
echo "$IMAGE"
