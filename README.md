# PhysioNet Image Batch Downloader

Resumable batch downloader for authorized PhysioNet image lists. It shows a live
progress bar, completion count, transfer speed, elapsed time, and estimated time
remaining.

## First-time setup

```bash
git clone https://github.com/YOUR_ACCOUNT/physionet-image-downloader.git chestimg
cd chestimg
cp /path/to/your/IMAGE_FILENAMES ./IMAGE_FILENAMES
chmod +x batch.sh run.sh
```

`IMAGE_FILENAMES` is deliberately ignored by Git. Do not commit it unless you
are certain you are allowed to share it.

## Run a batch

The script prompts for the PhysioNet username and password without displaying
the password:

```bash
./run.sh --start 11 --images 10 --jobs 5 --output ./downloads/batch_11_to_20
```

For a non-interactive run, set credentials only in the current shell:

```bash
PHYSIONET_USER='your_username' PHYSIONET_PASS='your_password' \
./run.sh --start 1 --images 50 --jobs 5 --output ./downloads/batch_1_to_50
```

## Options

```text
--list FILE       Use a filename list somewhere other than ./IMAGE_FILENAMES
--start NUMBER    Start at this 1-based non-empty list entry
--images NUMBER   Number of images to download
--jobs NUMBER     Number of parallel downloads (5 is the tested default)
--output DIR      Output directory
--replace         Re-download selected images instead of resuming/skipping them
```

Downloads require an account with access to the requested PhysioNet dataset and
acceptance of its data-use terms. Keep credentials and downloaded data private.
