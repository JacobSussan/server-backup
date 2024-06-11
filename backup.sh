#!/usr/bin/env bash
# Description:      Backup script for a LAMP server. Backs up specified databases, files, & directories.
# Author:           Jacob Sussan
# Date:             2024-06-12
# Version:          1.0
# Usage:            ./backup.sh
# Notes:            This script is intended to be run as root.
#
# Crontab example to run at 3:00AM every day:
# 0  3 *  *  * /path/to/backup.sh
#
# Extract a single file:
# tar -xvf file.tgz --fast-read path/to/file
#
# Extract entire backup
# tar -xvzf /path/to/yourfile.tgz

[[ $EUID -ne 0 ]] && echo "Error: This script must be run as root!" && exit 1

########## CONFIG ##########

# To decrypt backups, run:
# openssl enc -aes256 -in [encrypted backup] -out decrypted_backup.tgz -pass pass:[password] -d -md sha1
ENCRYPT_FILES=false 
ENCRYPT_PASSWORD="password"

BACKUP_DIR="/media/m1/backups/"
TEMP_DIR="/media/m1/backups/tmp/"
LOGFILE="/media/m1/backups/backup.log"

MYSQL_ROOT_PASSWORD="" # if you want to backup the MySQL database, enter the MySQL root password below, otherwise leave it blank
MYSQL_DATABASE_NAME[0]="" # list of database names that will be backed up. if you want backup ALL databases, leave it blank.

# list of files and directories that will be backed up in the tar backup
BACKUP_LIST[0]="/var/www/"
BACKUP_LIST[1]="/etc/apache2/sites-available/"
BACKUP_LIST[2]="/etc/fstab"
BACKUP_LIST[3]="/etc/letsencrypt/live/"
BACKUP_LIST[4]="/var/spool/cron/"

KEEP_BACKUPS_FOR="7" # days to store daily local backups
KEEP_MONTHLY_BACKUPS_FOR="6" # number of monthly backups to keep (1st day of month)
DELETE_REMOTE_FILES=false # delete remote file from Googole Drive or FTP server

RCLONE_NAME="" # rclone remote name
RCLONE_FOLDER="" # rclone remote folder name
UPLOAD_FTP=false # upload local file to FTP server 
UPLOAD_RCLONE=false # upload local file to Google Drive

FTP_HOST="" # if you want to upload to FTP server, enter the Hostname or IP below
FTP_USER="" # if you want to upload to FTP server, enter the FTP username below
FTP_PASS="" # if you want to upload to FTP server, enter the username's password below
FTP_DIR="" # if you want to upload to FTP server, enter the FTP remote folder below. for example: /storage/backups

########## END CONFIG ##########

# Date & Time
DAY=$(date +%d)
MONTH=$(date +%m)
YEAR=$(date +%C%y)
BACKUP_DATE=$(date +%Y%m%d%H%M%S)

BACKUP_FILE_NAME="${BACKUP_DIR}""$(hostname)"_"${BACKUP_DATE}".tgz # backup file name
ENC_BACKUP_FILE_NAME="${BACKUP_FILE_NAME}.enc" # encrypted backup file name
SQL_FILE="${TEMP_DIR}mysql_${BACKUP_DATE}.sql" # backup MySQL dump file name

log() {
    echo "$(date "+%Y-%m-%d %H:%M:%S")" "$1"
    echo -e "$(date "+%Y-%m-%d %H:%M:%S")" "$1" >>${LOGFILE}
}

# Check for list of binaries used in this script
check_commands() {
    # don't check mysql command if user is not backing up mysql
    if [ -z "${MYSQL_ROOT_PASSWORD}" ]; then
        BINARIES=(cat cd du date dirname echo openssl pwd rm tar)
    else
        BINARIES=(cat cd du date dirname echo openssl mysql mysqldump pwd rm tar)
    fi

    # if any binary isn't found, abort
    for BINARY in "${BINARIES[@]}"; do
        if [ ! "$(command -v "$BINARY")" ]; then
            log "$BINARY is not installed. Install it and try again"
            exit 1
        fi
    done

    # check rclone command
    RCLONE_COMMAND=false
    if [ "$(command -v "rclone")" ]; then
        RCLONE_COMMAND=true
    fi

    # check ftp command
    if ${UPLOAD_FTP}; then
        if [ ! "$(command -v "ftp")" ]; then
            log "ftp is not installed. Install it and try again"
            exit 1
        fi
    fi
}

calculate_size() {
    local file_name=$1
    local file_size=$(du -h $file_name 2>/dev/null | awk '{print $1}')
    if [ "x${file_size}" = "x" ]; then
        echo "unknown"
    else
        echo "${file_size}"
    fi
}

# Backup MySQL databases
mysql_backup() {
    if [ -z "${MYSQL_ROOT_PASSWORD}" ]; then
        log "MySQL root password not set, MySQL backup skipped"
    else
        log "MySQL dump start"
        mysql -u root -p"${MYSQL_ROOT_PASSWORD}" 2>/dev/null <<EOF
exit
EOF
        if [ $? -ne 0 ]; then
            log "MySQL root password is incorrect. Please check it and try again"
            exit 1
        fi
        if [[ "${MYSQL_DATABASE_NAME[@]}" == "" ]]; then
            mysqldump -u root -p"${MYSQL_ROOT_PASSWORD}" --all-databases >"${SQL_FILE}" 2>/dev/null
            if [ $? -ne 0 ]; then
                log "MySQL all databases backup failed"
                exit 1
            fi
            log "MySQL all databases dump file name: ${SQL_FILE}"
            # add MySQL dump file to BACKUP list
            BACKUP_LIST=(${BACKUP_LIST[@]} ${SQL_FILE})
        else
            for db in ${MYSQL_DATABASE_NAME[@]}; do
                unset DBFILE
                DBFILE="${TEMP_DIR}${db}_${BACKUP_DATE}.sql"
                mysqldump -u root -p"${MYSQL_ROOT_PASSWORD}" ${db} >"${DBFILE}" 2>/dev/null
                if [ $? -ne 0 ]; then
                    log "MySQL database name [${db}] backup failed, please check database name is correct and try again"
                    exit 1
                fi
                log "MySQL database name [${db}] dump file name: ${DBFILE}"
                # add MySQL dump file to BACKUP list
                BACKUP_LIST=(${BACKUP_LIST[@]} ${DBFILE})
            done
        fi
        log "MySQL dump completed"
    fi
}

start_backup() {
    [ "${#BACKUP_LIST[@]}" -eq 0 ] && echo "Error: You must modify the [$(basename $0)] config before run it!" && exit 1

    log "Tar backup file start"
    tar -zcPf ${BACKUP_FILE_NAME} ${BACKUP_LIST[@]}
    if [ $? -gt 1 ]; then
        log "Tar backup file failed"
        exit 1
    fi
    log "Tar backup file completed"

    # Encrypt tar file
    if ${ENCRYPT_FILES}; then
        log "Encrypt backup file start"
        openssl enc -aes256 -in "${BACKUP_FILE_NAME}" -out "${ENC_BACKUP_FILE_NAME}" -pass pass:"${ENCRYPT_PASSWORD}" -md sha1
        log "Encrypt backup file completed"

        # Delete unencrypted tar
        log "Delete unencrypted tar file: ${BACKUP_FILE_NAME}"
        rm -f ${BACKUP_FILE_NAME}
    fi

    # Delete MySQL temporary dump file
    for sql in $(ls ${TEMP_DIR}*.sql 2>/dev/null); do
        log "Delete MySQL temporary dump file: ${sql}"
        rm -f ${sql}
    done

    if ${ENCRYPT_FILES}; then
        OUT_FILE="${ENC_BACKUP_FILE_NAME}"
    else
        OUT_FILE="${BACKUP_FILE_NAME}"
    fi
    log "File name: ${OUT_FILE}, File size: $(calculate_size ${OUT_FILE})"
}

# transfer backup file to Google Drive
rclone_upload() {
    if ${UPLOAD_RCLONE} && ${RCLONE_COMMAND}; then
        [ -z "${RCLONE_NAME}" ] && log "Error: RCLONE_NAME can not be empty!" && return 1
        if [ -n "${RCLONE_FOLDER}" ]; then
            rclone ls ${RCLONE_NAME}:${RCLONE_FOLDER} 2>&1 >/dev/null
            if [ $? -ne 0 ]; then
                log "Create the path ${RCLONE_NAME}:${RCLONE_FOLDER}"
                rclone mkdir ${RCLONE_NAME}:${RCLONE_FOLDER}
            fi
        fi
        log "Tranferring backup file: ${OUT_FILE} to Google Drive"
        rclone copy ${OUT_FILE} ${RCLONE_NAME}:${RCLONE_FOLDER} >>${LOGFILE}
        if [ $? -ne 0 ]; then
            log "Error: Tranferring backup file: ${OUT_FILE} to Google Drive failed"
            return 1
        fi
        log "Tranferring backup file: ${OUT_FILE} to Google Drive completed"
    fi
}

# transfer backup file to FTP server
ftp_upload() {
    if ${UPLOAD_FTP}; then
        [ -z "${FTP_HOST}" ] && log "Error: FTP_HOST can not be empty!" && return 1
        [ -z "${FTP_USER}" ] && log "Error: FTP_USER can not be empty!" && return 1
        [ -z "${FTP_PASS}" ] && log "Error: FTP_PASS can not be empty!" && return 1
        [ -z "${FTP_DIR}" ] && log "Error: FTP_DIR can not be empty!" && return 1
        local FTP_OUT_FILE=$(basename ${OUT_FILE})
        log "Tranferring backup file: ${FTP_OUT_FILE} to FTP server"
        ftp -in ${FTP_HOST} 2>&1 >>${LOGFILE} <<EOF
user $FTP_USER $FTP_PASS
binary
lcd $BACKUP_DIR
cd $FTP_DIR
put $FTP_OUT_FILE
quit
EOF
        if [ $? -ne 0 ]; then
            log "Error: Tranferring backup file: ${FTP_OUT_FILE} to FTP server failed"
            return 1
        fi
        log "Tranferring backup file: ${FTP_OUT_FILE} to FTP server completed"
    fi
}

# Get file date
get_file_date() {
    #Approximate a 30-day month and 365-day year
    DAYS=$(($((10#${YEAR} * 365)) + $((10#${MONTH} * 30)) + $((10#${DAY}))))
    unset FILEYEAR FILEMONTH FILEDAY FILEDAYS FILEAGE
    FILEYEAR=$(echo "$1" | cut -d_ -f2 | cut -c 1-4)
    FILEMONTH=$(echo "$1" | cut -d_ -f2 | cut -c 5-6)
    FILEDAY=$(echo "$1" | cut -d_ -f2 | cut -c 7-8)
    if [[ "${FILEYEAR}" && "${FILEMONTH}" && "${FILEDAY}" ]]; then
        #Approximate a 30-day month and 365-day year
        FILEDAYS=$(($((10#${FILEYEAR} * 365)) + $((10#${FILEMONTH} * 30)) + $((10#${FILEDAY}))))
        FILEAGE=$((10#${DAYS} - 10#${FILEDAYS}))
        return 0
    fi
    return 1
}

# delete Google Drive's old backup file
delete_gdrive_file() {
    local FILENAME=$1
    if ${DELETE_REMOTE_FILES} && ${RCLONE_COMMAND}; then
        rclone ls ${RCLONE_NAME}:${RCLONE_FOLDER}/${FILENAME} 2>&1 >/dev/null
        if [ $? -eq 0 ]; then
            rclone delete ${RCLONE_NAME}:${RCLONE_FOLDER}/${FILENAME} >>${LOGFILE}
            if [ $? -eq 0 ]; then
                log "Google Drive's old backup file: ${FILENAME} has been deleted"
            else
                log "Failed to delete Google Drive's old backup file: ${FILENAME}"
            fi
        else
            log "Google Drive's old backup file: ${FILENAME} is not exist"
        fi
    fi
}

# delete FTP server's old backup file
delete_ftp_file() {
    local FILENAME=$1
    if ${DELETE_REMOTE_FILES} && ${UPLOAD_FTP}; then
        ftp -in ${FTP_HOST} 2>&1 >>${LOGFILE} <<EOF
user $FTP_USER $FTP_PASS
cd $FTP_DIR
del $FILENAME
quit
EOF
        if [ $? -eq 0 ]; then
            log "FTP server's old backup file: ${FILENAME} has been deleted"
        else
            log "Failed to delete FTP server's old backup file: ${FILENAME}"
        fi
    fi
}

# delete files older than KEEP_BACKUPS_FOR
clean_up_files() {
    cd ${BACKUP_DIR} || exit
    if ${ENCRYPT_FILES}; then
        LS=($(ls *.enc 2>/dev/null))
    else
        LS=($(ls *.tgz 2>/dev/null))
    fi

    # Separate files into daily and monthly backups
    daily_files=()
    monthly_files=()

    for f in ${LS[@]}; do
        get_file_date ${f}
        if [ $? -eq 0 ]; then
            FILEDAY=$(echo "$f" | cut -d_ -f2 | cut -c 7-8)
            if [ ${FILEDAY} -eq 01 ]; then
                monthly_files+=("$f")
            else
                daily_files+=("$f")
            fi
        fi
    done

    # Sort and delete old daily backups
    for f in ${daily_files[@]}; do
        get_file_date ${f}
        if [ $? -eq 0 ]; then
            if [[ ${FILEAGE} -gt ${KEEP_BACKUPS_FOR} ]]; then
                rm -f ${f}
                log "Old daily backup file name: ${f} has been deleted"
                delete_gdrive_file ${f}
                delete_ftp_file ${f}
            fi
        fi
    done

    # Sort monthly backups and keep only the latest N backups
    if [ ${#monthly_files[@]} -gt ${KEEP_MONTHLY_BACKUPS_FOR} ]; then
        sorted_monthly_files=$(printf '%s\n' "${monthly_files[@]}" | sort -r)
        count=0
        for f in ${sorted_monthly_files}; do
            if [ ${count} -ge ${KEEP_MONTHLY_BACKUPS_FOR} ]; then
                rm -f ${f}
                log "Old monthly backup file name: ${f} has been deleted"
                delete_gdrive_file ${f}
                delete_ftp_file ${f}
            fi
            count=$((count + 1))
        done
    fi
}


# progress
STARTTIME=$(date +%s)

# Check if the backup folders exist and are writeable
[ ! -d "${BACKUP_DIR}" ] && mkdir -p ${BACKUP_DIR}
[ ! -d "${TEMP_DIR}" ] && mkdir -p ${TEMP_DIR}

log "Backup progress start"
check_commands
mysql_backup
start_backup
log "Backup progress complete"

log "Upload progress start"
rclone_upload
ftp_upload
log "Upload progress complete"

log "Cleaning up"
clean_up_files
ENDTIME=$(date +%s)
DURATION=$((ENDTIME - STARTTIME))
log "All done"
log "Backup and transfer completed in ${DURATION} seconds"
