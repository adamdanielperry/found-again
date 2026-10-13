# Recover Photos

A small Mac app that copies deleted photos and videos off a camera SD card into a folder you choose. It only reads the card.

Fujifilm cards (JPEG and RAF) use FAT32 or ExFAT. Deleting a photo in the camera usually leaves the file name and the picture data in place until a new photo overwrites that space.

## Use it

```bash
./scripts/build-app.sh
open dist/DataRecover.app
```

1. Insert the SD card. Stop taking new photos on it until recovery is done.
2. Open Recover Photos. The card should appear in the list. A Fujifilm card is labeled with the camera model when the card still has the camera's folders.
3. Choose the folder where recovered photos should go. Pick a folder on the Mac, not on the card.
4. Click **Look for deleted photos**. macOS asks for your password so the card can be read. Finder hides the card during the scan, then shows it again.
5. If macOS says it is blocking the card, click **Allow card access**. In Full Disk Access, click +, choose Recover Photos, and turn it on. Then scan again.
6. Review the list and click **Save selected**. Photos appear while a long search is still running.

The camera often erases the file name and leaves the picture. When the file list has nothing, the app reads the card and looks for JPEG, RAF, and video data. A 256 GB card can take a while. Turn on **Search the whole card even when some file names are found** if you also want that search after some names were recovered.

## What it can and can't do

Photos deleted in the camera are the usual case, and the file name is often still there (`DCIM/100_FUJI/DSCF0001.JPG`). The app also looks for JPEG, RAF, HEIC, and video by their contents when you run a deep scan.

It can't bring back a photo whose space has already been reused by a newer shot. Those files show up as damaged, or they don't show up at all. Nothing the app does writes to the card.
