#!/bin/bash -eu

log "Moving clips to archive..."

NUM_FILES_MOVED=0
NUM_FILES_FAILED=0
NUM_FILES_DELETED=0
NUM_FILES_DUPLICATES=0

function connectionmonitor {
  while true
  do
    for i in {1..5}
    do
      if timeout 6 /root/bin/archive-is-reachable.sh $ARCHIVE_HOST_NAME
      then
        # sleep and then continue outer loop
        sleep 5
        continue 2
      fi
    done
    log "connection dead, killing archive-clips"
    # The archive loop might be stuck on an unresponsive server, so kill it hard.
    # (should be no worse than losing power in the middle of an operation)
    kill -9 $1
    return
  done
}

function moveclips() {
  ROOT="$1"
  PATTERN="$2"
  SUB=$(basename $ROOT)

  if [ ! -d "$ROOT" ]
  then
    log "$ROOT does not exist, skipping"
    return
  fi

  while read file_name
  do
    if [ -d "$ROOT/$file_name" ]
    then
      log "Creating output directory '$SUB/$file_name'"
      if ! mkdir -p "$ARCHIVE_MOUNT/$SUB/$file_name"
      then
        log "Failed to create '$SUB/$file_name', check that archive server is writable and has free space"
        return
      fi
    elif [ -f "$ROOT/$file_name" ]
    then
      size=$(stat -c%s "$ROOT/$file_name")
      if [ $size -lt 100000 ]
      then
        log "'$SUB/$file_name' is only $size bytes"
        rm "$ROOT/$file_name"
        NUM_FILES_DELETED=$((NUM_FILES_DELETED + 1))
      else
        log "Moving '$SUB/$file_name'"
        outdir=$(dirname "$file_name")
        if [ -e "$ARCHIVE_MOUNT/$SUB/$file_name" -a $(stat -c%s "$ARCHIVE_MOUNT/$SUB/$file_name") -eq $size ]
        then
          log "File '$SUB/$file_name' already exists with correct size"
          rm "$ROOT/$file_name"
          NUM_FILES_DUPLICATES=$((NUM_FILES_DUPLICATES + 1))
        elif mv -f "$ROOT/$file_name" "$ARCHIVE_MOUNT/$SUB/$outdir"
        then
          log "Moved '$SUB/$file_name'"
          NUM_FILES_MOVED=$((NUM_FILES_MOVED + 1))
        else
          log "Failed to move '$SUB/$file_name'"
          NUM_FILES_FAILED=$((NUM_FILES_FAILED + 1))
        fi
      fi
    else
      log "$SUB/$file_name not found"
    fi
  done <<< $(cd "$ROOT"; find $PATTERN)
}

connectionmonitor $$ &

# check old mounts for previous sync attempts that may have failed
for clipdir in $(find /backingfiles/snapshots/ -type d -name SavedClips -or -name SentryClips | sort -u)
do
  log "Archiving clips from a previous failed attempt: $clipdir"
  MNTPOINT=$(echo "$clipdir" | sed -e 's/\/TeslaCam.*//')
  mount -o remount,rw "$MNTPOINT"
  moveclips "$clipdir" '*'
  rmdir --ignore-fail-on-non-empty "$clipdir"/* || true
  rmdir --ignore-fail-on-non-empty "$clipdir" || true
  mount -o remount,ro "$MNTPOINT"
done

# new file name pattern, firmware 2019.*
moveclips "$CAM_MOUNT/TeslaCam/SavedClips" '*'

# v10 firmware adds a SentryClips folder
moveclips "$CAM_MOUNT/TeslaCam/SentryClips" '*'

kill %1

# delete empty directories under SavedClips and SentryClips
rmdir --ignore-fail-on-non-empty "$CAM_MOUNT/TeslaCam/SavedClips"/* "$CAM_MOUNT/TeslaCam/SentryClips"/* || true

log "Moved $NUM_FILES_MOVED file(s), failed to copy $NUM_FILES_FAILED, deleted $NUM_FILES_DELETED, with $NUM_FILES_DUPLICATES duplicates."

if [ $NUM_FILES_MOVED -gt 0 ]
then
  /root/bin/send-push-message "TeslaUSB:" "Moved $NUM_FILES_MOVED dashcam file(s), failed to copy $NUM_FILES_FAILED, deleted $NUM_FILES_DELETED, with $NUM_FILES_DUPLICATES duplicates."
fi

log "Finished moving clips to archive."
