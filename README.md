# makemkv-fw-dump

**English** | [Italiano](README.it.md)

A small script that generates the **firmware dump of your Blu-ray drive** for MakeMKV, the file recent MakeMKV versions need to stop hanging on Blu-ray discs.

It was born to fix my own [Automatic Ripping Machine (ARM)](https://github.com/automatic-ripping-machine/automatic-ripping-machine) setup, but the problem is in MakeMKV itself, so it works for two use cases:

- **ARM users:** the script finds the ARM container, stops it while it works, and can install the dump in ARM's `.MakeMKV` folder for you (`--install`).
- **Anyone using `makemkvcon` without ARM** (your own scripts, or ARM not installed yet): the script uses the free beta key (or your own key with `-k`) and you copy the dump into your `~/.MakeMKV` folder. See [Without ARM](#without-arm).

Under the hood it builds an older MakeMKV version (1.17.6) inside a throwaway Docker container, reads one disc, collects the `dump_FW_*.tgz` file MakeMKV creates, and cleans up. Nothing is installed on the host apart from a Docker image you can remove afterwards.

## The problem

With recent MakeMKV versions (1.17.7 and later), ARM can get stuck on Blu-ray discs. This is tracked in [ARM issue #1545](https://github.com/automatic-ripping-machine/automatic-ripping-machine/issues/1545). Typical symptoms:

- the ARM job log stops right after `Starting MakeMKV rip`;
- `makemkvcon` sits at 100% CPU and never finishes;
- the drive does not spin or read;
- running `makemkvcon` by hand shows `Downloading latest SDF ...` and nothing else;
- DVDs usually work, Blu-ray discs do not.

In my tests the missing piece was the **firmware dump** of the drive (`dump_FW_<ID>.tgz` in the `.MakeMKV` folder). With that single file next to `settings.conf`, MakeMKV 1.18.4 inside ARM started immediately. Older MakeMKV versions create the dump automatically on the first disc read; this script does exactly that, in isolation.

The same hang happened with MakeMKV 1.18.4 installed directly on the host, outside ARM, so the dump is useful for any `makemkvcon` setup, not only ARM.

## Requirements

- Linux host with Docker (the one running ARM is fine)
- `lsscsi` and `udevadm` (`sudo apt install lsscsi`)
- A Blu-ray disc to read (any disc works, the dump depends on the drive, not on the disc)
- A MakeMKV key. The script reads it from ARM's `settings.conf`; if ARM has not run MakeMKV yet (no Blu-ray ripped so far) or is not installed, it downloads the current free beta key from the [MakeMKV forum](https://forum.makemkv.com/forum/viewtopic.php?f=5&t=1053), like ARM does. To use your own key, pass it with `-k`
- ARM is **not** required: see [Without ARM](#without-arm)
- Internet access to download MakeMKV 1.17.6 from [makemkv.com/download/old](https://www.makemkv.com/download/old/)

## Usage

```bash
chmod +x makemkv-fw-dump.sh
sudo ./makemkv-fw-dump.sh
```

The script:

1. finds the ARM container and stops it, so ARM does not grab the disc. It uses `docker stop` and, at the end (even on errors), `docker start`: the container keeps its original configuration;
2. finds the Blu-ray drive and its matching `sg` device;
3. reads the MakeMKV key from ARM's `settings.conf`, in the host folder mounted at `/home/arm` in the container, or downloads the free beta key if there is none yet;
4. builds MakeMKV 1.17.6 in a Docker image (a few minutes, first run only);
5. asks you to insert a Blu-ray, then reads it with a clean `.MakeMKV` folder that contains only the key;
6. saves the dump and the full log in `./makemkv-fw-dump-YYYYMMDD-HHMMSS/` and compares it with any dump ARM already has.

**Do not insert the disc before the script asks for it**, otherwise ARM may start a job and eject the disc when it is stopped.

By default the dump is **not** copied into ARM's folder, so you can check it first. Add `--install` to copy it there with the right owner; `--install` also adds `cfg_UpdateEnable = "0"` and `cfg_SdfDownload = "0"` to ARM's `settings.conf` (see [Using the dump with ARM](#using-the-dump-with-arm)).

### Options

| Option | Description |
|---|---|
| `-d, --device /dev/srX` | Drive to use. If omitted, the Blu-ray drive is picked automatically when there is only one. |
| `-k, --key KEY` | MakeMKV key. If omitted, it is read from ARM's `settings.conf`, or the free beta key is downloaded. |
| `-o, --output DIR` | Output folder for the dump and the log. |
| `-c, --container NAME` | ARM container name. If omitted, the script looks for a running container named `arm`, `arm-rippers` or `automatic-ripping-machine`, or running an image whose name contains `automatic-ripping-machine`. |
| `--install` | Also copy the dump into ARM's `.MakeMKV` folder, with the same owner as that folder, and set `cfg_UpdateEnable` and `cfg_SdfDownload` to `"0"` in ARM's `settings.conf`. |
| `--remove-image` | Remove the Docker image at the end. |
| `-h, --help` | Show help. |

Environment variables: `MKV_VERSION` (default `1.17.6`), `ARM_CONTAINER` (same as `-c`), `ARM_MAKEMKV_DIR` (ARM's `.MakeMKV` folder on the host, if it cannot be detected from the container; default `/home/arm/.MakeMKV`), `TIMEOUT` in seconds (default `600`).

If ARM is installed without Docker, the script cannot stop it: stop it yourself before running the script.

### Example output

```
==> Read summary
    MakeMKV v1.17.6 linux(x64-release) started
    Using direct disc access mode
    Processing BD+ code, please be patient - this may take up to few minutes
    BD+ code processed, got 1 FUT(s) for 1 clip(s)
    Operation successfully completed
    TCOUNT:20

==> Dump created: /home/user/makemkv-fw-dump-20261027-205311/dump_FW_74E1F1B75CCA043A0290.tgz
```

## Using the dump with ARM

1. Copy the dump into ARM's `.MakeMKV` folder (the one mounted as `/home/arm` in the container) and set the owner to ARM's user:

   ```bash
   sudo cp makemkv-fw-dump-*/dump_FW_*.tgz /home/arm/.MakeMKV/
   sudo chown $(stat -c '%u:%g' /home/arm/.MakeMKV) /home/arm/.MakeMKV/dump_FW_*.tgz
   ```

2. Add these two lines (`--install` does it for you) to `/home/arm/.MakeMKV/settings.conf` to stop MakeMKV from checking for updates and downloading SDF data at every run. ARM's key update only changes the `app_Key` line, so they are kept:

   ```
   cfg_UpdateEnable = "0"
   cfg_SdfDownload = "0"
   ```

3. Insert a Blu-ray: the rip should start after ARM's manual-override wait.

## Without ARM

The script also works when ARM is not installed yet, or when you use `makemkvcon` with your own scripts. In that case there is no ARM `settings.conf` to read the key from, so the script downloads the free beta key. To use your own key, pass it with `-k`:

```bash
sudo ./makemkv-fw-dump.sh
sudo ./makemkv-fw-dump.sh -k "T-XXXXXXXXXXXX"
```

Do not use `--install`: the dump stays in the output folder. Then:

- **Installing ARM later:** start ARM once so it creates its `.MakeMKV` folder, then copy the dump there as shown in [Using the dump with ARM](#using-the-dump-with-arm). This way ARM works with Blu-ray discs from the first rip.
- **Your own `makemkvcon` scripts:** copy the dump into the `.MakeMKV` folder in the home directory of the user that runs `makemkvcon` (for example `~/.MakeMKV/`, or `/root/.MakeMKV/` if it runs as root), next to `settings.conf`:

  ```bash
  mkdir -p ~/.MakeMKV
  cp makemkv-fw-dump-*/dump_FW_*.tgz ~/.MakeMKV/
  ```

## Notes

- The dump is **specific to the drive** (the ID is in the file name). Run the script again if you change drive.
- You only need to do this once per drive. Keep a copy of the `.MakeMKV` folder in your backups.
- DVDs are not affected by the issue.
- To test MakeMKV inside ARM by hand, run it as ARM's user: `sudo docker exec -u arm arm makemkvcon -r info dev:/dev/srX`. As root you get `This application version is too old`, because root has no key.

## Tested on

- HP EliteDesk 800 G3 SFF, Ubuntu Server 26.04 LTS, Docker
- ARM 2.24.4 (MakeMKV 1.18.4 inside the container)
- Pioneer BDR-TD04 in a USB enclosure

Feedback from other drives and setups is welcome: open an issue with your log (`makemkvcon.log` in the output folder).

## Disclaimer

This project is not affiliated with MakeMKV or with the Automatic Ripping Machine project. It only automates the build and the first run of an older public MakeMKV release. Use it with discs you own and respect the laws of your country.

## License

[MIT](LICENSE)
