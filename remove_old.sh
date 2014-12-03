#!/bin/bash

# ------------- remove some old backups --------------------------------
# remove certain snapshots to achieve an exponential distribution in time of the backups (1,2,4,8,...)

SNAPSHOT_DST=$1
HOST_SRC=$2
NAME=$3
CHATTR=$4

for b in 512 256 128 64 32 16 8 4; do
  let a=b/2+1
  let f=0 #this flag is set to 1 when we find the 1st snapshot in the range b..a
  for i in $(seq -f'%03g' "${b}" -1 "${a}"); do
    if [ -d "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.${i}" ]; then
      if [ "${f}" -eq 0 ]; then
        let f=1
      else
        echo "$(date +%Y-%m-%d_%H:%M:%S) Removing ${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.${i} ..."
        [ "${CHATTR}" -eq 1 ] && chattr -R -i "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.${i}" &>/dev/null
        rm -rf "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.${i}"
      fi
    fi
  done
done
