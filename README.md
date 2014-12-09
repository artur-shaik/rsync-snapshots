Create a snapshot backup of specified directories/files into remote server via rsync over ssh.

Based on script described here: http://www.pointsoftware.ch/howto-local-and-remote-snapshot-backup-using-rsync-with-hard-links/, but this script give ability to backup local to remote.

PURPOSE
=======
Rsync over ssh is used to transfer the files with a delta-transfer algorithm to transfer only minimal parts of the files and improve speed; rsync uses for this the previous backup as reference. This reference is also used to create hard links instead of files when possible and thus save disk space. If original and reference file have identical content but different timestamps or permissions then no hard link is created. A rotation of all backups renames snapshot.X into snapshot.X+1 and removes backups with X>512. About 10 backups with non-linear distribution are kept in rotation; for example with X=1,2,3,4,8,16,32,64,128,256,512. The snapshots folders are protected read-only against all users including root using 'chattr'.

USAGE 
=====
`rsync-snapshot.sh [CONFIGURATION_FILE]`

If no CONFIGURATION_FILE, local one (default.rshot.conf) will be used.

CONFIGURATION
=============
```bash
SNAPSHOT_DST="/home/$USER/backup"           # where to save data on remote server
SSH_HOST="$USER@backupserver"               # remote server address
SSH_PORT="22"                               # remote server ssh port
REMOTE_TMP="/tmp"                           # temporary directory on remote server
INCLUDE_LIST_FILE="./rsync-include.txt"     # incudes directories and files to backup, see man rsync for more info
```

FILES
=====
rsync-snapshot.sh - the backup script, entry point

rsync-include.txt - rsync filter rules

default.rshot.conf - default example configuration

remove_old.sh, remove_snapshot.sh, rotate_and_clean_up.sh - inner helpers, don't use it directly
