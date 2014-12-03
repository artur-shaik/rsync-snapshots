#!/bin/bash

# ------------- finish and clean up ------------------------------------
# protect the backup against modification with chattr +immutable

SNAPSHOT_DST=$1
HOST_SRC=$2
NAME=$3
CHATTR=$4

if [ "${CHATTR}" -eq 1 ]; then
  echo "$(date +%Y-%m-%d_%H:%M:%S) Setting recursively immutable flag of ${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.000 ..."
  ssh $DST_HOST chattr -R +i "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.000" &>/dev/null
fi

# rotate the backups
if [ -d "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.512" ]; then #remove snapshot.512
  echo "Removing ${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.512 ..."
  [ "${CHATTR}" -eq 1 ] && chattr -R -i "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.512" &>/dev/null
  rm -rf "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.512"
fi
[ -h "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.last" ] && rm -f "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.last"
for i in $(seq -f'%03g' 511 -1 000); do
  if [ -d "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.${i}" ]; then
    let j=${i##+(0)}+1
    j=$(printf "%.3d" "${j}")
    echo "Renaming ${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.${i} into ${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.${j} ..."
    [ "${CHATTR}" -eq 1 ] && chattr -i "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.${i}" &>/dev/null
    mv "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.${i}" "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.${j}"
    [ "${CHATTR}" -eq 1 ] && chattr +i "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.${j}" &>/dev/null
    [ ! -h "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.last" ] && ln -s "${NAME}.${j}" "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.last"
  fi
done
