#!/bin/bash

set -x

id=$(cat container.id)
docker stop $id
docker rm $id

#unmount the DANDI FUSE mount so dandifs.py exits (best-effort)
[ -z "$TASK_ID" ] && TASK_ID="debug"
fusermount -u "/mnt/dandi/$TASK_ID" 2>/dev/null || umount "/mnt/dandi/$TASK_ID" 2>/dev/null || true
