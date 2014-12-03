#!/bin/bash

SUCCESS=0
NO_CONFIG=1
RSYNC_ERROR=2
SSH_ERROR=3
MULTI_INSTANCE=4
CONFIGURATION_ERROR=5

function show_help
{
    cat << "EOF"
    USAGE: rsync-snapshot.sh [CONFIGURATION_FILE]

    PURPOSE: create a snapshot backup of specified directories/files into remote server via rsync over ssh. 

    If no CONFIGURATION_FILE, local one (default.rshot.conf) will be used.

    Rsync over ssh is used to transfer the files with a delta-transfer 
    algorithm to transfer only minimal parts of the files and improve 
    speed; rsync uses for this the previous backup as reference.
    This reference is also used to create hard links instead of files when
    possible and thus save disk space. If original and reference file have
    identical content but different timestamps or permissions then no hard link
    is created.
    A rotation of all backups renames snapshot.X into snapshot.X+1 and removes
    backups with X>512. About 10 backups with non-linear distribution are kept
    in rotation; for example with X=1,2,3,4,8,16,32,64,128,256,512.
    The snapshots folders are protected read-only against all users including
    root using 'chattr'.

    FILES:
    rsync-snapshot.sh       the backup script, entry point
    rsync-include.txt       rsync filter rules
    default.rshot.conf      default example configuration
    remove_old.sh, 
    remove_snapshot.sh, 
    rotate_and_clean_up.sh  inner helpers, don't use it directly

EOF

    exit $SUCCESS
}

function echolog
{
    echo "$(date +%Y-%m-%d_%H:%M:%S) ${HOST_SRC}: $1"
}

function echologn
{
    echo -n "$(date +%Y-%m-%d_%H:%M:%S) ${HOST_SRC}: $1"
}

function cd_to_app_dir
{
    SOURCE="${BASH_SOURCE[0]}"
    while [ -h "$SOURCE" ]; do
        DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
        SOURCE="$(readlink "$SOURCE")"
        [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" 
    done
    DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
    cd $DIR
}

function setup
{
    SNAPSHOT_DST="/home/$USER/backup"
    SSH_HOST="$USER@backupserver"
    SSH_PORT="22"
    REMOTE_TMP="/tmp"
    NAME="snapshot"
    LOG="rsync.log"
    INCLUDE_LIST_FILE="./rsync-include.txt"
    MIN_MIBSIZE=5000            # older snapshots (except snapshot.001) are removed if free disk <= MIN_MIBSIZE. the script may exit without performing a backup if free disk is still short.
    OVERWRITE_LAST=0            # if free disk space is too small, then this option let us remove snapshot.001 as well and retry once
    MAX_MIBSIZE=80000           # older snapshots (except snapshot.001) are removed if their size >= MAX_MIBSIZE. the script performs a backup even if their size is too big.
    BWLIMIT=100000              # bandwidth limit in KiB/s. 0 does not use slow-down. this allows to avoid rsync consuming too much system performance
    CHATTR=1                    # to use 'chattr' command and protect the backups again modification and deletion
    DU=1                        # to use 'du' command and calculate the size of existing backups, disable it if you have many backups and it is getting too slow (for example on BACKUPSERVER)
    SOURCE="/"

    HOST_LOCAL="$(hostname)"
    if [ -z "${SRC}" ] || [ "${SRC}" == "localhost" ]; then
        HOST_SRC="${HOST_LOCAL}"
    else
        HOST_SRC="${SRC}"
    fi

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
        --bwlimit=${BWLIMIT}
        --compress \
        --rsh=\"ssh -p $SSH_PORT \" \
        --rsync-path=\"/usr/bin/rsync\""

    source $1
}

function ssh_command
{
    ssh -p $SSH_PORT $SSH_HOST $1
}

function check_snapshot_folder
{
    if ssh_command "[ ! -d \"${SNAPSHOT_DST}\" ]"; then
        echolog "Sorry, folder ${SNAPSHOT_DST} is missing. Exiting..."
        echolog "=== Snapshot failed. ==="
        exit $CONFIGURATION_ERROR
    fi

    if ssh_command "[ ! -d \"${SNAPSHOT_DST}/${HOST_SRC}\" ]"; then
        echologn "Creating folder ${SNAPSHOT_DST}/${HOST_SRC} ..."
        ssh_command "mkdir -p \"${SNAPSHOT_DST}/${HOST_SRC}\""
        if [ $? -eq 0 ]; then
            echo " done"
        else
            echo " failure"
            exit $SSH_ERROR
        fi
    fi
}

function check_already_running
{
    if pgrep -f "/bin/\w*sh \w*rsync-snapshot\.sh" | grep -qv "$$"; then
        echolog "Sorry, rsync is already running in the background. Exiting..."
        echolog "=== Snapshot failed. ==="
        exit $MULTI_INSTANCE
    fi
}

function cp_scripts_to_remote
{
    scp -P $SSH_PORT ./remove_old.sh $SSH_HOST:$REMOTE_TMP > /dev/null
    scp -P $SSH_PORT ./remove_snapshot.sh $SSH_HOST:$REMOTE_TMP > /dev/null
    scp -P $SSH_PORT ./rotate_and_clean_up.sh $SSH_HOST:/tmp > /dev/null

    if  [[ $? != 0 ]]; then
        echolog "Cannot write to remote tmp folder: $REMOTE_TMP"
        exit $SSH_ERROR
    fi

    ssh_command "chmod +x /tmp/remove_old.sh"
    ssh_command "chmod +x /tmp/remove_snapshot.sh"
    ssh_command "chmod +x /tmp/rotate_and_clean_up.sh"
}

function remove_old
{
    ssh_command "/tmp/remove_old.sh $SNAPSHOT_DST $HOST_SRC $NAME $CHATTR"
}

function estimate_disk_space
{
    while :; do #this loop is executed a 2nd time if OVERWRITE_LAST was ==1 and snapshot.001 got removed
        OOVERWRITE_LAST="${OVERWRITE_LAST}"

        echologn "Testing needed free disk space ..."
        mkdir -p "${NAME}.test-free-disk-space"
        chmod -R 775 "${NAME}.test-free-disk-space"
        cat /dev/null > ${LOG}

        LNKDST=$(ssh_command "find \"${SNAPSHOT_DST}/\" -maxdepth 2 -type d -name \"${NAME}.001\" -printf \" --link-dest=%p\"")

        for i in ${LNKDST//--link-dest=/}; do
            if ssh_command "[ -d \"${i}\" ]" && [ "${CHATTR}" -eq 1 ] && [ $(ssh_command "lsattr -d \"${i}\" | cut -b5") == "i" ]; then
                ssh_command "chattr -R -i \"${i}\"" &>/dev/null #unprotect last snapshots to use hardlinks
            fi
        done

        CMD="rsync --dry-run ${OPTION} -e \"ssh -p $SSH_PORT\" --include-from=\"${INCLUDE_LIST_FILE}\" ${LNKDST} \"${SOURCE}\" \"${SSH_HOST}:${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.test-free-disk-space\""
        eval $CMD >> "${LOG}"

        RES=$?
        if [ "${RES}" -ne 0 ] && [ "${RES}" -ne 23 ] && [ "${RES}" -ne 24 ]; then
            echolog "Sorry, error in rsync execution (value ${RES}). Exiting..."
            echolog "=== Snapshot failed. ==="
            exit $RSYNC_ERROR
        fi

        let i=$(tail -100 "${LOG}" | grep 'Total transferred file size:' | cut -d " " -f5)/1048576
        echo " ${i} MiB needed."

        rm -rf "${LOG}" 
        ssh_command "/tmp/remove_snapshot.sh $SNAPSHOT_DST $HOST_SRC $NAME $CHATTR $DU $((${MIN_MIBSIZE} + ${i})) $((${MAX_MIBSIZE} - ${i}))"

        if [ "${OOVERWRITE_LAST}" == "${OVERWRITE_LAST}" ]; then #no need to retry
            break
        fi
    done
}

function create_snapshot
{
    echolog "Creating folder ${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.000 ..."
    ssh_command "mkdir -p \"${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.000\""
    ssh_command "chmod 775 \"${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.000\""

    cat /dev/null >"${LOG}"

    echologn "Creating backup of ${HOST_SRC} into ${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.000"

    if [ -n "${LNKDST}" ]; then
        echo " hardlinked with${LNKDST//--link-dest=/} ..."
    else
        echo " not hardlinked ..."
    fi

    CMD="rsync -vv ${OPTION} -e \"ssh -p $SSH_PORT\" --include-from=\"${INCLUDE_LIST_FILE}\" ${LNKDST} \"${SOURCE}\" \"${SSH_HOST}:${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.000\""
    eval $CMD >> "${LOG}"

    RES=$?
    if [ "${RES}" -ne 0 ] && [ "${RES}" -ne 23 ] && [ "${RES}" -ne 24 ]; then
        echolog "Sorry, error in rsync execution (value ${RES}). Exiting..."
        echolog "=== Snapshot failed. ==="
        exit $RSYNC_ERROR
    fi

    for i in ${LNKDST//--link-dest=/}; do
        if [ -d "${i}" ] && [ "${CHATTR}" -eq 1 ] && [ $(ssh_command "lsattr -d \"${i}\" | cut -b5") != "i" ]; then
            ssh_command "chattr -R +i \"${i}\"" &>/dev/null #undo unprotection that was needed to use hardlinks
        fi
    done

    scp -P $SSH_PORT "${LOG}" "${SSH_HOST}:${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.000/${LOG}" > /dev/null
    rm "${LOG}"
    ssh_command "gzip -f \"${SNAPSHOT_DST}/${HOST_SRC}/${NAME}.000/${LOG}\""
}

function rotate
{
    ssh_command "/tmp/rotate_and_clean_up.sh $SNAPSHOT_DST $HOST_SRC $NAME $CHATTR > /dev/null"

    OVERWRITE_LAST=0 #next call of remove_snapshot() will not remove snapshot.001
    ssh_command "/tmp/remove_snapshot.sh $SNAPSHOT_DST $HOST_SRC $NAME $CHATTR $DU ${MIN_MIBSIZE} ${MAX_MIBSIZE}" > /dev/null
}

function clean_up
{
    ssh_command "rm /tmp/remove_old.sh"
    ssh_command "rm /tmp/remove_snapshot.sh"
    ssh_command "rm /tmp/rotate_and_clean_up.sh"
}

function main
{
    if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
        show_help
    fi

    cd_to_app_dir

    if [[ $# -eq 1 ]]; then
        CONFIGURATION_FILE=$1
    else
        CONFIGURATION_FILE="./default.rshot.conf"
    fi

    if [ ! -f $CONFIGURATION_FILE ]; then
        echolog "Cannot read configuration file: $CONFIGURATION_FILE"
        exit $NO_CONFIG
    fi

    setup $CONFIGURATION_FILE

    echolog "=== Snapshot backup is created into ${SSH_HOST}:${SNAPSHOT_DST}/${HOST_SRC}/${NAME} ==="
    STARTDATE=$(date +%s)

    check_snapshot_folder
    check_already_running

    cp_scripts_to_remote
    remove_old

    estimate_disk_space

    create_snapshot

    rotate
    clean_up

    echolog "=== Snapshot backup successfully done in $(($(date +%s) - ${STARTDATE})) sec. ==="
    exit $SUCCESS
}

main
#eof

