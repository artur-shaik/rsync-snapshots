#!/bin/bash
# ----------------------------------------------------------------------
# created by francois scheurer on 20070323
# derivate from mikes handy rotating-filesystem-snapshot utility
# see http://www.mikerubel.org/computers/rsync_snapshots
# ----------------------------------------------------------------------
#rsync note:
#    1) rsync -avz /src/foo  /dest      => ok, creates /dest/foo, like cp -a /src/foo /dest
#    2) rsync -avz /src/foo/ /dest/foo  => ok, creates /dest/foo, like cp -a /src/foo/. /dest/foo (or like cp -a /src/foo /dest)
#    3) rsync -avz /src/foo/ /dest/foo/ => ok, same as 2)
#    4) rsync -avz /src/foo/ /dest      => dangerous!!! overwrite dest content, like cp -a /src/foo/. /dest
#      solution: remove trailing / at /src/foo/ => 1)
#      minor problem: rsync -avz /src/foo /dest/foo => creates /dest/foo/foo, like mkdir /dest/foo && cp -a /src/foo /dest/foo
#    main options:
#      -H --hard-links
#      -a equals -rlptgoD (no -H,-A,-X)
#        -r --recursive
#        -l --links
#        -p --perms
#        -t --times
#        -g --group
#        -o --owner
#        -D --devices --specials
#      -x --one-file-system
#      -S --sparse
#      --numeric-ids
#    useful options:
#      -n --dry-run
#      -z --compress
#      -y --fuzzy
#      --bwlimit=X limit disk IO to X kB/s
#      -c --checksum
#      -I --ignore-times
#      --size-only
#    other options:
#      -v --verbose
#      -P equals --progress --partial
#      -h --human-readable
#      --stats
#      -e'ssh -o ServerAliveInterval=60'
#      --delete
#      --delete-delay
#      --delete-excluded
#      --ignore-existing
#      -i --itemize-changes
#      --stop-at
#      --time-limit
#      --rsh=\"ssh -p ${HOST_PORT} -i /root/.ssh/rsync_rsa -l root\" 
#      --rsync-path=\"/usr/bin/rsync\""
#    quickcheck options:
#      the default behavior is to skip files with same size & mtime on destination
#      mtime = last data write access
#      atime = last data read access (can be ignored with noatime mount option or with chattr +A)
#      ctime = last inode change (write access, change of permission or ownership)
#      note that a checksum is always done after a file synchronization/transfer
#      --modify-window=X ignore mtime differences less or equal to X sec
#      --size-only skip files with same size on destination (ignore mtime)
#      -c --checksum skip files with same MD5 checksum on destination (ignore size & mtime, all files are read once, then the list of files to be resynchronized is read a second time, there is a lot of disk IO but network trafic is minimal if many files are identical; log includes only different files)
#      -I --ignore-times never skip files (all files are resynchronized, all files are read once, there is more network trafic than with --checksum but less disk IO and hence is faster than --checksum if net is fast or if most files are different; log includes all files)
#      --link-dest does the quickcheck on another reference-directory and makes hardlinks if quickcheck succeeds
#        (however, if mtime is different and --perms is used, the reference file is copied in a new inode)
#    see also this link for a rsync tutorial: http://www.thegeekstuff.com/2010/09/rsync-command-examples/
#todo:
#                 'du' slow on many snapshot.X..done
#  autokill after n minutes.
#                 if disk full, its better to replace the snapshot.001 than to cancel and have a very old backup (even if it may fail to create the snapshot and ends with 0 backups)..done
#                 rsync-snapshot for oracle redo logs..old
#                 'find'-list with md5 signatures -> .gz file stored aside rsync.log.gz inside the snapshot.X folder; this file will be move to parent dir /backup/snapshot/localhost/ before deletion of a snapshot; this file will also be used to extract an incremental backup with tape-arch.sh..done (md5sum calculation with rsync-list.sh for acm14=18m58 and only 5m27 with a reference file. speedup is ~250-300%)
#  realtime freedisk display with echo $(($(stat -f -c "%f" /backup/snapshot/) * 4096 / 1024))
#  use authorized_keys with restriction of bash (command=) and set sshd_config with PermitRootLogin=forced-commands-only, see http://troy.jdmz.net/rsync/index.html http://www.snailbook.com/faq/restricted-scp.auto.html
#  note: rsync lists all files in snapshot.X disregarding inclusion patterns, this is slow.




# ------------- the help page ------------------------------------------
if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
  cat << "EOF"
Version 2.01 2013-01-16

USAGE: rsync-snapshot.sh HOST [--recheck]

PURPOSE: create a snapshot backup of the whole filesystem into the folder
  '/backup/snapshot/HOST/snapshot.001'.
  If HOST is 'localhost' it is replaced with the local hostname.
  If HOST is a remote host then rsync over ssh is used to transfer the files
  with a delta-transfer algorithm to transfer only minimal parts of the files
  and improve speed; rsync uses for this the previous backup as reference.
  This reference is also used to create hard links instead of files when
  possible and thus save disk space. If original and reference file have
  identical content but different timestamps or permissions then no hard link
  is created.
  A rotation of all backups renames snapshot.X into snapshot.X+1 and removes
  backups with X>512. About 10 backups with non-linear distribution are kept
  in rotation; for example with X=1,2,3,4,8,16,32,64,128,256,512.
  The snapshots folders are protected read-only against all users including
  root using 'chattr'.
  The --recheck option forces a sync of all files even if they have same mtime
  & size; it is can verify a backup and fix corrupted files;
  --recheck recalculates also the MD5 integrity signatures without using the
  last signature-file as precalculation.
  Some features like filter rules, MD5, chattr, bwlimit and per server retention
  policy can be configured by modifying the scripts directly.

FILES:
    /backup/snapshot/rsync/rsync-snapshot.sh  the backup script
    /backup/snapshot/rsync/rsync-list.sh      the md5 signature script
    /backup/snapshot/rsync/rsync-include.txt  the filter rules

Examples:
  (nice -5 ./rsync-snapshot.sh >log &) ; tail -f log
  cd /backup/snapshot; for i in $(ls -A); do nice -10 /backup/snapshot/rsync/rsync-snapshot.sh $i; done
EOF
  exit 1
fi

# ------ go to application directory --
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
cd $DIR

# ------ tuning options, file locations and constants --
SRC="$1" #name of backup source, may be a remote or local hostname
OPT="$2" #options (--recheck)
HOST_PORT=22 #port of source of backup
SCRIPT_PATH="/home/ash/Soft/datasync"
SNAPSHOT_DST="/home/ash/backup" #destination folder
DST_HOST="ash@desk"
NAME="snapshot" #backup name
LOG="rsync.log"
MIN_MIBSIZE=5000 # older snapshots (except snapshot.001) are removed if free disk <= MIN_MIBSIZE. the script may exit without performing a backup if free disk is still short.
OVERWRITE_LAST=0 # if free disk space is too small, then this option let us remove snapshot.001 as well and retry once
MAX_MIBSIZE=80000 # older snapshots (except snapshot.001) are removed if their size >= MAX_MIBSIZE. the script performs a backup even if their size is too big.
#old: SPEED=5 # 1 is slow, 100 is fast, 100000 faster and 0 does not use slow-down. this allows to avoid rsync consuming too much system performance
BWLIMIT=100000 # bandwidth limit in KiB/s. 0 does not use slow-down. this allows to avoid rsync consuming too much system performance
BACKUPSERVER="" # this server connects to all other to download filesystems and create remote snapshot backups
MD5LIST=0 #to compute a list of md5 integrity signatures of all backuped files, need 'rsync-list.sh'
CHATTR=1 # to use 'chattr' command and protect the backups again modification and deletion
DU=1 # to use 'du' command and calculate the size of existing backups, disable it if you have many backups and it is getting too slow (for example on BACKUPSERVER)
SOURCE="/" #source folder to backup

HOST_LOCAL="$(hostname)" #local hostname
#HOST_SRC="${SRC:-${HOST_LOCAL}}" #explicit source hostname, default is local hostname
if [ -z "${SRC}" ] || [ "${SRC}" == "localhost" ]; then
  HOST_SRC="${HOST_LOCAL}" #explicit source hostname, default is local hostname
else
  HOST_SRC="${SRC}" #explicit source hostname
fi

if [ "${HOST_LOCAL}" == "${BACKUPSERVER}" ]; then #if we are on BACKUPSERVER then do some fine tuning
  MD5LIST=1
  MIN_MIBSIZE=35000 #needed free space for chunk-file tape-arch.sh
  MAX_MIBSIZE=12000
  DU=0 # NB: 'du' is currently disabled on BACKUPSERVER for performance reasons
elif [ "${HOST_LOCAL}" == "${HOST_SRC}" ]; then #else if we are on a generic server then do other some fine tuning
  if [ "${HOST_SRC}" == "ZRHSV-TST01" ]; then
    MIN_MIBSIZE=500; CHATTR=0; DU=0; MD5LIST=0
  fi
fi

# ------ initialization --
shopt -s extglob #enable extended pattern matching operators

OPTION="--stats \
  --recursive \
  --links \
  --perms \
  --times \
  --group \
  --owner \
  --devices \
  --hard-links \
  --numeric-ids \
  --delete \
  --delete-excluded \
  --bwlimit=${BWLIMIT}"
#  --progress
#  --size-only
#  --stop-at
#  --time-limit
#  --sparse

if [ "${HOST_SRC}" != "${HOST_LOCAL}" ]; then #option for a remote server
  SOURCE="${HOST_SRC}:${SOURCE}"
  OPTION="${OPTION} \
  --compress \
  --rsh=\"ssh -p ${HOST_PORT} -i ~/.ssh/rsync_rsa \" \
  --rsync-path=\"/usr/bin/rsync\""
fi
if [ "${OPT}" == "--recheck" ]; then
  OPTION="${OPTION} \
  --ignore-times"
elif [ -n "${OPT}" ]; then
  echo "Try rsync-snapshot.sh --help ."
  exit 2
fi

# ------ check conditions --
echo "$(date +%Y-%m-%d_%H:%M:%S) ${HOST_SRC}: === Snapshot backup is created into ${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.001 ==="
STARTDATE=$(date +%s)

# make sure we have a correct snapshot folder
if ssh $DST_HOST [ ! -d "${SNAPSHOT_DST}/${HOST_SRC}" ]; then
  echo "Sorry, folder ${SNAPSHOT_DST}/${HOST_SRC} is missing. Exiting..."
  echo "$(date +%Y-%m-%d_%H:%M:%S) ${HOST_SRC}: === Snapshot failed. ==="
  exit 2
fi

# make sure we do not have started already rsync-snapshot.sh or rsync process (started by rsync-cp.sh or by a remote rsync-snapshot.sh) in the background.
if [ "${HOST_LOCAL}" != "${BACKUPSERVER}" ]; then #because BACKUPSERVER need sometimes to perform an rsync-cp.sh it must disable the check of "already started".
  if pgrep -f "/bin/\w*sh \w*rsync-snapshot\.sh" | grep -qv "$$"; then
    echo "Sorry, rsync is already running in the background. Exiting..."
    echo "$(date +%Y-%m-%d_%H:%M:%S) ${HOST_SRC}: === Snapshot failed. ==="
    exit 2
  fi
fi

scp ./remove_old.sh $DST_HOST:/tmp > /dev/null
ssh $DST_HOST chmod +x /tmp/remove_old.sh
ssh $DST_HOST "/tmp/remove_old.sh $SNAPSHOT_DST $HOST_SRC $NAME $CHATTR" > /dev/null
ssh $DST_HOST rm /tmp/remove_old.sh

scp ./remove_snapshot.sh $DST_HOST:/tmp > /dev/null
ssh $DST_HOST chmod +x /tmp/remove_snapshot.sh

# perform an estimation of required disk space for the new backup
while :; do #this loop is executed a 2nd time if OVERWRITE_LAST was ==1 and snapshot.001 got removed
  OOVERWRITE_LAST="${OVERWRITE_LAST}"
  echo -n "$(date +%Y-%m-%d_%H:%M:%S) Testing needed free disk space ..."
  mkdir -p "${NAME}.test-free-disk-space"
  chmod -R 775 "${NAME}.test-free-disk-space"
  cat /dev/null > ${LOG}
  LNKDST=$(ssh $DST_HOST find "${SNAPSHOT_DST}/" -maxdepth 2 -type d -name "${NAME}.001" -printf " --link-dest=%p")
  for i in ${LNKDST//--link-dest=/}; do
    if ssh $DST_HOST [ -d "${i}" ] && [ "${CHATTR}" -eq 1 ] && [ $(ssh $DST_HOST lsattr -d "${i}" | cut -b5) == "i" ]; then
      ssh $DST_HOST chattr -R -i "${i}" &>/dev/null #unprotect last snapshots to use hardlinks
    fi
  done
  eval rsync \
    --dry-run \
    ${OPTION} \
    --include-from="${SCRIPT_PATH}/rsync-include.txt" \
    ${LNKDST} \
    "${SOURCE}" "${DST_HOST}:${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.test-free-disk-space" >> "${LOG}"
  RES=$?
  if [ "${RES}" -ne 0 ] && [ "${RES}" -ne 23 ] && [ "${RES}" -ne 24 ]; then
    echo "Sorry, error in rsync execution (value ${RES}). Exiting..."
    echo "$(date +%Y-%m-%d_%H:%M:%S) ${HOST_SRC}: === Snapshot failed. ==="
    exit 2
  fi
  let i=$(tail -100 "${LOG}" | grep 'Total transferred file size:' | cut -d " " -f5)/1048576
  echo " ${i} MiB needed."
  rm -rf "${LOG}" 
  ssh $DST_HOST /tmp/remove_snapshot.sh $SNAPSHOT_DST $HOST_SRC $NAME $CHATTR $DU $((${MIN_MIBSIZE} + ${i})) $((${MAX_MIBSIZE} - ${i}))
  if [ "${OOVERWRITE_LAST}" == "${OVERWRITE_LAST}" ]; then #no need to retry
    break
  fi
done

# ------ create the snapshot backup --
echo "$(date +%Y-%m-%d_%H:%M:%S) Creating folder ${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.000 ..."
ssh $DST_HOST mkdir -p "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.000"
ssh $DST_HOST chmod 775 "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.000"
cat /dev/null >"${LOG}"
echo -n "$(date +%Y-%m-%d_%H:%M:%S) Creating backup of ${HOST_SRC} into ${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.000"
if [ -n "${LNKDST}" ]; then
  echo " hardlinked with${LNKDST//--link-dest=/} ..."
else
  echo " not hardlinked ..."
fi
eval rsync \
  -vv \
  ${OPTION} \
  --include-from="${SCRIPT_PATH}/rsync-include.txt" \
  ${LNKDST} \
  "${SOURCE}" "${DST_HOST}:${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.000" >>"${LOG}"
RES=$?
if [ "${RES}" -ne 0 ] && [ "${RES}" -ne 23 ] && [ "${RES}" -ne 24 ]; then
  echo "Sorry, error in rsync execution (value ${RES}). Exiting..."
  echo "$(date +%Y-%m-%d_%H:%M:%S) ${HOST_SRC}: === Snapshot failed. ==="
  exit 2
fi
for i in ${LNKDST//--link-dest=/}; do
  if [ -d "${i}" ] && [ "${CHATTR}" -eq 1 ] && [ $(ssh $DST_HOST lsattr -d "${i}" | cut -b5) != "i" ]; then
    ssh $DST_HOST chattr -R +i "${i}" &>/dev/null #undo unprotection that was needed to use hardlinks
  fi
done
scp "${LOG}" "${DST_HOST}:${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.000/${LOG}" > /dev/null
ssh $DST_HOST gzip -f "${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.000/${LOG}"
rm "${LOG}"

scp ./rotate_and_clean_up.sh $DST_HOST:/tmp > /dev/null
ssh $DST_HOST chmod +x /tmp/rotate_and_clean_up.sh
ssh $DST_HOST "/tmp/rotate_and_clean_up.sh $SNAPSHOT_DST $HOST_SRC $NAME $CHATTR > /dev/null"
ssh $DST_HOST rm /tmp/rotate_and_clean_up.sh

# remove additional backups if free disk space is short
OVERWRITE_LAST=0 #next call of remove_snapshot() will not remove snapshot.001
ssh $DST_HOST "/tmp/remove_snapshot.sh $SNAPSHOT_DST $HOST_SRC $NAME $CHATTR $DU ${MIN_MIBSIZE} ${MAX_MIBSIZE}" > /dev/null
echo "$(date +%Y-%m-%d_%H:%M:%S) ${HOST_SRC}: === Snapshot backup successfully done in $(($(date +%s) - ${STARTDATE})) sec. ==="
exit 0
#eof

ssh $DST_HOST rm /tmp/remove_snapshot.sh
