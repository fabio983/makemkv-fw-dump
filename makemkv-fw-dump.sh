#!/usr/bin/env bash
#
# makemkv-fw-dump.sh
#
# Generates the firmware dump of a Blu-ray drive (dump_FW_*.tgz) with
# MakeMKV 1.17.6, inside a throwaway Docker container.
#
# Why: starting with MakeMKV 1.17.7, Automatic Ripping Machine (ARM) can
# hang on Blu-ray discs when the drive's firmware dump is missing from the
# .MakeMKV folder (see ARM issue #1545). An older MakeMKV version creates
# the dump on the first disc read; after that, the current version works.
#
# By default the script does NOT touch ARM's folder: it saves the dump in a
# separate output folder. Use --install to copy it into ARM's .MakeMKV folder.
#
# Usage:
#   sudo ./makemkv-fw-dump.sh [-d /dev/srX] [-k KEY] [-o DIR] [--install] [--remove-image]
#
# Options:
#   -d, --device     Drive to use (e.g. /dev/sr1). If omitted, the script
#                    picks the Blu-ray drive when there is exactly one.
#   -k, --key        MakeMKV key (beta or registered). If omitted, it is read
#                    from ARM's settings.conf (see ARM_MAKEMKV_DIR); if that
#                    has no key yet, the current free beta key is downloaded
#                    from the MakeMKV forum.
#   -o, --output     Folder where the dump and the log are saved.
#                    Default: ./makemkv-fw-dump-YYYYMMDD-HHMMSS
#   -c, --container  Name of the ARM container. If omitted, the script looks
#                    for a running container named arm, arm-rippers or
#                    automatic-ripping-machine, or running an image whose
#                    name contains automatic-ripping-machine.
#   --install        Also copy the dump into ARM's .MakeMKV folder, with the
#                    same owner as that folder.
#   --remove-image   Remove the Docker image at the end (by default it is
#                    kept, so a second run does not need to rebuild it).
#   -h, --help       Show this help.
#
# The ARM container is stopped with "docker stop" and restarted with
# "docker start": it keeps its original configuration.
# ARM's .MakeMKV folder is taken from the host folder mounted at /home/arm
# in the container, or from ARM_MAKEMKV_DIR, or defaults to /home/arm/.MakeMKV.
#
# Optional environment variables:
#   MKV_VERSION      MakeMKV version to build (default 1.17.6)
#   ARM_CONTAINER    Same as --container
#   ARM_MAKEMKV_DIR  ARM's .MakeMKV folder on the host
#   TIMEOUT          Max seconds for the disc read (default 600)
#
# https://github.com/fabio983/makemkv-fw-dump  -  MIT License

set -euo pipefail

MKV_VERSION="${MKV_VERSION:-1.17.6}"
IMAGE="makemkv-fw-dump:${MKV_VERSION}"
ARM_CONTAINER="${ARM_CONTAINER:-}"
ARM_MAKEMKV_DIR="${ARM_MAKEMKV_DIR:-}"
TIMEOUT="${TIMEOUT:-600}"
RUN_NAME="makemkv-fw-dump-$$"

DEVICE=""
KEY=""
OUT_DIR=""
INSTALL=0
REMOVE_IMAGE=0

WORK_DIR=""
ARM_WAS_RUNNING=0

log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

cleanup() {
  local rc=$?
  docker rm -f "$RUN_NAME" >/dev/null 2>&1 || true
  [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
  if [[ $ARM_WAS_RUNNING -eq 1 ]]; then
    log "Restarting the ARM container ($ARM_CONTAINER)"
    docker start "$ARM_CONTAINER" >/dev/null || info "Could not restart $ARM_CONTAINER: start it manually."
  fi
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- Arguments -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--device)    DEVICE="${2:-}"; shift 2 ;;
    -k|--key)       KEY="${2:-}"; shift 2 ;;
    -o|--output)    OUT_DIR="${2:-}"; shift 2 ;;
    -c|--container) ARM_CONTAINER="${2:-}"; shift 2 ;;
    --install)      INSTALL=1; shift ;;
    --remove-image) REMOVE_IMAGE=1; shift ;;
    -h|--help)      usage ;;
    *)              die "Unknown option: $1 (use -h for help)" ;;
  esac
done

# --- Preliminary checks ----------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run the script with sudo."
for cmd in docker lsscsi udevadm md5sum; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd (e.g. sudo apt install lsscsi)"
done

# --- Find the ARM container ------------------------------------------------
if [[ -z "$ARM_CONTAINER" ]]; then
  mapfile -t ARM_CANDIDATES < <(
    docker ps --format '{{.Names}} {{.Image}}' \
      | awk '$1=="arm" || $1=="arm-rippers" || $1=="automatic-ripping-machine" || $2 ~ /automatic-ripping-machine/ {print $1}' \
      | sort -u
  )
  if [[ ${#ARM_CANDIDATES[@]} -eq 1 ]]; then
    ARM_CONTAINER="${ARM_CANDIDATES[0]}"
  elif [[ ${#ARM_CANDIDATES[@]} -gt 1 ]]; then
    die "More than one possible ARM container (${ARM_CANDIDATES[*]}): pick one with -c NAME"
  fi
fi

if [[ -n "$ARM_CONTAINER" ]]; then
  docker container inspect "$ARM_CONTAINER" >/dev/null 2>&1 || die "Container $ARM_CONTAINER not found."
  log "ARM container: $ARM_CONTAINER"
else
  log "No running ARM container found"
  info "If ARM is installed without Docker, stop it before inserting the disc, or it will grab the disc."
fi

# --- ARM's .MakeMKV folder ---------------------------------------------------
if [[ -z "$ARM_MAKEMKV_DIR" && -n "$ARM_CONTAINER" ]]; then
  ARM_HOME="$(docker container inspect -f '{{range .Mounts}}{{if eq .Destination "/home/arm"}}{{.Source}}{{end}}{{end}}' "$ARM_CONTAINER" 2>/dev/null || true)"
  [[ -n "$ARM_HOME" ]] && ARM_MAKEMKV_DIR="$ARM_HOME/.MakeMKV"
fi
ARM_MAKEMKV_DIR="${ARM_MAKEMKV_DIR:-/home/arm/.MakeMKV}"
ARM_SETTINGS="$ARM_MAKEMKV_DIR/settings.conf"
info "ARM's .MakeMKV folder: $ARM_MAKEMKV_DIR"

# --- Stop ARM first, otherwise it grabs the disc ---------------------------
if [[ -n "$ARM_CONTAINER" ]] && [[ "$(docker container inspect -f '{{.State.Running}}' "$ARM_CONTAINER")" == "true" ]]; then
  log "Temporarily stopping $ARM_CONTAINER (docker stop), it will be restarted at the end with its own configuration"
  docker stop "$ARM_CONTAINER" >/dev/null
  ARM_WAS_RUNNING=1
  info "If ARM was processing a disc, it ejects it on exit: you will reinsert it later."
fi

# --- Drive -----------------------------------------------------------------
log "Optical drives found"
lsscsi -g | awk '$2=="cd/dvd"' | sed 's/^/    /' || true

if [[ -z "$DEVICE" ]]; then
  mapfile -t BD_DRIVES < <(lsscsi -g | awk '$2=="cd/dvd"' | grep -i 'BD' | awk '{print $(NF-1)}')
  if [[ ${#BD_DRIVES[@]} -eq 1 ]]; then
    DEVICE="${BD_DRIVES[0]}"
    info "Using the Blu-ray drive: $DEVICE"
  else
    die "Cannot pick the drive automatically: specify it with -d /dev/srX"
  fi
fi

[[ -b "$DEVICE" ]] || die "$DEVICE does not exist or is not a block device."
SG_DEVICE="$(lsscsi -g | awk -v d="$DEVICE" '$(NF-1)==d {print $NF}')"
[[ -n "$SG_DEVICE" && -c "$SG_DEVICE" ]] || die "Cannot find the sg device for $DEVICE."
info "Generic SCSI device: $SG_DEVICE"

# --- Key -------------------------------------------------------------------
BETA_KEY_URL="https://forum.makemkv.com/forum/viewtopic.php?f=5&t=1053"
fetch_beta_key() {
  # Same source ARM uses (scripts/update_key.sh)
  local page
  if command -v curl >/dev/null 2>&1; then
    page="$(curl -fsSL --retry 3 "$BETA_KEY_URL" 2>/dev/null)" || return 1
  elif command -v wget >/dev/null 2>&1; then
    page="$(wget -qO- --tries=3 "$BETA_KEY_URL" 2>/dev/null)" || return 1
  else
    return 1
  fi
  grep -oP 'T-[\w\d@]{66}' <<<"$page" | head -n1
}

if [[ -z "$KEY" && -r "$ARM_SETTINGS" ]]; then
  KEY="$(grep -m1 '^app_Key' "$ARM_SETTINGS" | sed -E 's/^app_Key *= *"(.*)".*/\1/')"
  [[ -n "$KEY" ]] && info "MakeMKV key read from $ARM_SETTINGS"
fi
if [[ -z "$KEY" ]]; then
  info "No MakeMKV key found (ARM has not run MakeMKV yet?): downloading the free beta key"
  KEY="$(fetch_beta_key || true)"
  [[ -n "$KEY" ]] || die "Cannot download the beta key from $BETA_KEY_URL: pass the key with -k."
  info "Using the current MakeMKV beta key"
fi

# --- Output folder ---------------------------------------------------------
[[ -n "$OUT_DIR" ]] || OUT_DIR="$(pwd)/makemkv-fw-dump-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"
LOG_FILE="$OUT_DIR/makemkvcon.log"

# --- Image with the older MakeMKV ------------------------------------------
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "Image $IMAGE already present, skipping the build"
else
  log "Building MakeMKV $MKV_VERSION in a Docker image (a few minutes, first run only)"
  docker build -t "$IMAGE" - <<EOF
FROM ubuntu:22.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \\
 && apt-get install -y --no-install-recommends build-essential pkg-config libc6-dev \\
    libssl-dev libexpat1-dev libavcodec-dev zlib1g-dev wget ca-certificates \\
 && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp/build
# makemkv.com can drop the connection mid-download: retry each file and check
# the archive before extracting it
RUN for part in oss bin; do \\
      f="makemkv-\$part-${MKV_VERSION}.tar.gz"; n=0; \\
      until wget -nv --tries=3 --timeout=60 -O "\$f" "https://www.makemkv.com/download/old/\$f" && gzip -t "\$f"; do \\
        n=\$((n+1)); \\
        if [ "\$n" -ge 5 ]; then echo "Download of \$f failed after \$n attempts" >&2; exit 1; fi; \\
        echo "Download of \$f incomplete, retrying (\$n/5)..."; rm -f "\$f"; sleep 10; \\
      done; \\
    done
RUN tar xzf makemkv-oss-${MKV_VERSION}.tar.gz \\
 && tar xzf makemkv-bin-${MKV_VERSION}.tar.gz \\
 && cd makemkv-oss-${MKV_VERSION} && ./configure --disable-gui && make -j"\$(nproc)" && make install && cd .. \\
 && cd makemkv-bin-${MKV_VERSION} && mkdir -p tmp && echo accepted > tmp/eula_accepted && make install && cd .. \\
 && ldconfig && rm -rf /tmp/build
WORKDIR /root
EOF
fi

# --- Disc in the drive -----------------------------------------------------
disc_present() { udevadm info --query=property --name="$DEVICE" 2>/dev/null | grep -q '^ID_CDROM_MEDIA=1'; }
wait_disc() {
  # The drive may take a few seconds to report the disc after insertion
  local i
  for i in $(seq 1 30); do
    disc_present && return 0
    sleep 1
  done
  return 1
}
log "Disc"
read -r -p "    Insert (or reinsert) a Blu-ray in $DEVICE and press Enter once it stops spinning... "
until wait_disc; do
  read -r -p "    No disc detected in $DEVICE. Insert it and press Enter... "
done
info "Disc detected in $DEVICE"

# --- Read the disc with the older MakeMKV ----------------------------------
WORK_DIR="$(mktemp -d)"
mkdir -p "$WORK_DIR/.MakeMKV"
printf 'app_Key = "%s"\n' "$KEY" > "$WORK_DIR/.MakeMKV/settings.conf"

log "Reading the disc with MakeMKV $MKV_VERSION (timeout ${TIMEOUT}s, may take a few minutes)"
set +e
docker run --rm --name "$RUN_NAME" \
  --device "$DEVICE" --device "$SG_DEVICE" \
  -v "$WORK_DIR:/root" \
  "$IMAGE" \
  timeout "$TIMEOUT" makemkvcon -r --cache=1 info "dev:$DEVICE" > "$LOG_FILE" 2>&1
RUN_RC=$?
set -e

{
  echo
  echo "### Content of .MakeMKV after the read"
  ls -la "$WORK_DIR/.MakeMKV"
} >> "$LOG_FILE"

# --- Result ----------------------------------------------------------------
log "Read summary"
grep -E 'MSG:(1005|3007|3326|3328|5010|5011|5021|5073)|TCOUNT' "$LOG_FILE" \
  | sed -E 's/^MSG:[0-9]+,[0-9]+,[0-9]+,"([^"]*)".*/\1/' | sed 's/^/    /' || true

if grep -q 'MSG:5021' "$LOG_FILE"; then
  die "MakeMKV $MKV_VERSION reports the version is too old or the key is not valid. Log: $LOG_FILE"
fi
[[ $RUN_RC -eq 124 ]] && info "Warning: the read was stopped by the timeout (${TIMEOUT}s)."

DUMP_FILE="$(find "$WORK_DIR/.MakeMKV" -maxdepth 1 -name 'dump_FW_*.tgz' | head -n1)"
if [[ -z "$DUMP_FILE" ]]; then
  echo
  info "Last lines of the log:"
  tail -n 15 "$LOG_FILE" | sed 's/^/      /'
  die "The firmware dump was not created. Full log: $LOG_FILE"
fi

cp "$DUMP_FILE" "$OUT_DIR/"
DUMP_NAME="$(basename "$DUMP_FILE")"

log "Dump created: $OUT_DIR/$DUMP_NAME"
info "MD5 new dump:  $(md5sum "$OUT_DIR/$DUMP_NAME" | awk '{print $1}')"

ARM_DUMP="$ARM_MAKEMKV_DIR/$DUMP_NAME"
if [[ -f "$ARM_DUMP" ]]; then
  info "MD5 ARM dump:  $(md5sum "$ARM_DUMP" | awk '{print $1}')  ($ARM_DUMP)"
else
  info "No dump with the same name in ARM's folder yet."
fi

# Give the output folder back to the user who ran sudo
if [[ -n "${SUDO_USER:-}" ]]; then
  chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$OUT_DIR"
fi

if [[ $INSTALL -eq 1 ]]; then
  [[ -d "$ARM_MAKEMKV_DIR" ]] || die "ARM folder $ARM_MAKEMKV_DIR not found: dump left in $OUT_DIR"
  OWNER="$(stat -c '%u:%g' "$ARM_MAKEMKV_DIR")"
  cp "$OUT_DIR/$DUMP_NAME" "$ARM_MAKEMKV_DIR/"
  chown "$OWNER" "$ARM_MAKEMKV_DIR/$DUMP_NAME"
  log "Dump installed in $ARM_MAKEMKV_DIR (owner $OWNER)"
fi

if [[ $REMOVE_IMAGE -eq 1 ]]; then
  log "Removing image $IMAGE"
  docker rmi "$IMAGE" >/dev/null || true
else
  info "Image $IMAGE was kept. To remove it: sudo docker rmi $IMAGE"
fi

if [[ $INSTALL -eq 0 ]]; then
  log "Done. To use it with ARM (after checking it):"
  info "sudo cp \"$OUT_DIR/$DUMP_NAME\" $ARM_MAKEMKV_DIR/"
  info "sudo chown \$(stat -c '%u:%g' $ARM_MAKEMKV_DIR) $ARM_MAKEMKV_DIR/$DUMP_NAME"
else
  log "Done."
fi
