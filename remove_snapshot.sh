#!/bin/bash

# remove additional backups if free disk space is short

SNAPSHOT_DST=$1
HOST_SRC=$2
NAME=$3
CHATTR=$4
DU=$5
MIN_MIBSIZE2=$6
MAX_MIBSIZE2=$7

for i in $(seq -f'%03g' 512 -1 001); do
if [ -d "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.${i}" ] || [ ${i} -eq 1 ]; then
  [ ! -h "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.last" ] && [ -d "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.${i}" ] && ln -s "${NAME}.${i}" "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.last"
  let d=0 #disk space used by snapshots and free disk space are ok
  echo -n "$(date +%Y-%m-%d_%H:%M:%S) Checking free disk space... "
  FREEDISK=$(df -m ${SNAPSHOT_DST} | tail -1 | sed -e 's/  */ /g' | cut -d" " -f4 | sed -e 's/M*//g')
  echo -n "${FREEDISK} MiB free. "
  if [ ${FREEDISK} -ge ${MIN_MIBSIZE2} ]; then
    echo "Ok, bigger than ${MIN_MIBSIZE2} MiB."
    if [ "${DU}" -eq 0 ]; then #avoid slow 'du'
      break
    else
      echo -n "$(date +%Y-%m-%d_%H:%M:%S) Checking disk space used by ${SNAPSHOT_DST}/${HOST_SRC} ... "
      USEDDISK=$(du -ms "${SNAPSHOT_DST}/${HOST_SRC}/" | cut -f1)
      echo -n "${USEDDISK} MiB used. "
      if [ ${USEDDISK} -le ${MAX_MIBSIZE2} ]; then
        echo "Ok, smaller than ${MAX_MIBSIZE2} MiB."
        break
      else
        let d=2 #disk space used by snapshots is too big
      fi
    fi
  else
    let d=1 #free disk space is too small
  fi
  if [ ${d} -ne 0 ]; then #we need to remove snapshots
    if [ ${i} -ne 1 ]; then
      echo "Removing ${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.${i} ..."
      [ "${CHATTR}" -eq 1 ] && chattr -R -i "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.${i}" &>/dev/null
      rm -rf "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.${i}"
      [ -h "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.last" ] && rm -f "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.last"
    else #all snapshots except snapshot.001 are removed
      if [ ${d} -eq 1 ]; then #snapshot.001 causes that free space is too small
        if [ "${OVERWRITE_LAST}" -eq 1 ]; then #last chance: remove snapshot.001 and retry once
          OVERWRITE_LAST=0
          echo "Warning, free disk space will be smaller than ${MIN_MIBSIZE} MiB."
          echo "$(date +%Y-%m-%d_%H:%M:%S) OVERWRITE_LAST enabled. Removing ${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.001 ..."
          rm -rf "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.001"
          [ -h "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.last" ] && rm -f "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.last"
        else
          for j in ${LNKDST//--link-dest=/}; do
            if [ -d "${j}" ] && [ "${CHATTR}" -eq 1 ] && [ $(lsattr -d "${j}" | cut -b5) != "i" ]; then
              chattr -R +i "${j}" &>/dev/null #undo unprotection that was needed to use hardlinks
            fi
          done
          [ ! -h "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.last" ] && ln -s "${NAME}.${j}" "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.last"
          echo "Sorry, free disk space will be smaller than ${MIN_MIBSIZE} MiB. Exiting..."
          echo "$(date +%Y-%m-%d_%H:%M:%S) ${HOST_SRC}: === Snapshot failed. ==="
          exit 2
        fi
      elif [ ${d} -eq 2 ]; then #snapshot.001 causes that disk space used by snapshots is too big
        echo "Warning, disk space used by ${SNAPSHOT_DST}/${HOST_SRC} will be bigger than ${MAX_MIBSIZE} MiB. Continuing anyway..."
      fi
    fi
  fi
fi
done
