#!/bin/bash
# Builds a camera-card disk image with some files deleted, for trying the app without a real card.
#   scripts/dev/make-test-card.sh <folder> [exfat|formatted]
#   SOURCES=<folder of real photos> scripts/dev/make-test-card.sh <folder>   use real photos (e.g. for screenshots)
# "formatted" makes a FAT32 card, deletes nothing, then reformats it, so only the deep scan can find the photos.
set -euo pipefail
cd "$(dirname "$0")/../.."
WORK="${1:?folder}"
MODE="${2:-exfat}"
COUNT="${COUNT:-16}"
mkdir -p "$WORK"
PHOTOS="$WORK/photos"
rm -rf "$PHOTOS"
swift scripts/dev/make-photos.swift "$PHOTOS" "$COUNT" Canon "Canon EOS R6" ${SOURCES:+"$SOURCES"} >/dev/null
IMAGE="$WORK/card-$MODE.dmg"
rm -f "$IMAGE"
FS=ExFAT; [[ "$MODE" == formatted ]] && FS=FAT32
hdiutil create -size 512m -fs "$FS" -volname EOS_DIGITAL -layout MBRSPUD -type UDIF "$IMAGE" >/dev/null
DEV=$(hdiutil attach "$IMAGE" | awk '/\/Volumes\//{print $1; exit}')
DISK=$(echo "$DEV" | sed -E 's|/dev/(disk[0-9]+).*|\1|')
VOL=$(mount | awk -v d="$DEV" '$1==d{print $3; exit}')
mkdir -p "$VOL/DCIM/100CANON"
# -p keeps each photo's date, so the card shows them on the days they were taken.
cp -p "$PHOTOS"/*.JPG "$VOL/DCIM/100CANON/"
cp "/System/Library/Wallpapers/.default/Golden Gate.mov" "$VOL/DCIM/100CANON/MVI_4120.MOV"
touch -t 202608161942 "$VOL/DCIM/100CANON/MVI_4120.MOV"
printf 'Lisbon and the Algarve\n14 to 17 August\n\nFri  Old town, dinner at the harbour\nSat  Beach day\nSun  Boat trip, sunset at the marina\nMon  Drive to the lakes\n' > "$WORK/itinerary.txt"
/usr/sbin/cupsfilter "$WORK/itinerary.txt" > "$VOL/Itinerary.pdf" 2>/dev/null || true
touch -t 202608101830 "$VOL/Itinerary.pdf"
sync
if [[ "$MODE" == formatted ]]; then
  hdiutil detach "$DEV" -quiet
  DEV=$(hdiutil attach -nomount "$IMAGE" | awk 'NR==1{print $1}')
  newfs_msdos -F 32 -v EOS_DIGITAL "${DEV}s1" >/dev/null 2>&1
else
  # Keep the first two and last two photos; everything else was "deleted in the camera".
  KEEP_FIRST=$(ls "$VOL/DCIM/100CANON"/IMG_*.JPG | head -2)
  KEEP_LAST=$(ls "$VOL/DCIM/100CANON"/IMG_*.JPG | tail -2)
  for photo in "$VOL"/DCIM/100CANON/IMG_*.JPG; do
    if ! grep -qx "$photo" <<< "$KEEP_FIRST"$'\n'"$KEEP_LAST"; then rm "$photo"; fi
  done
  rm "$VOL/DCIM/100CANON/MVI_4120.MOV" "$VOL/Itinerary.pdf"
  sync
fi
hdiutil detach "/dev/$DISK" -quiet || hdiutil detach "/dev/$DISK" -force -quiet
echo "$IMAGE"
