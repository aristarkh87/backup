#!/bin/bash
#  
#  Copyright 2017 Oleg Dolgikh <aristarkh@aristarkh.net>
#  
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 3 of the License, or
#  (at your option) any later version.
#  
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#  
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
#  MA 02110-1301, USA.
#  
#  

if [ "$1" ]
then
    source "$1"
else
    echo "Usage: $0 config-file.conf"
    exit 1
fi

# Functions
send_email() {
    if [ yes = "${enable_mail_notification}" ]
    then
        send_command="sendemail -f ${mail_from} -t ${mail_to} -u ${mail_subject} -s ${mail_server}"
        cat ${backup_error} | ${send_command}
    fi
}

check_enable_gzip() {
    if [ yes = "${enable_gzip}" ]
    then
        tar_options="--gzip ${tar_options}"
        backup_extention='tar.gz'
    else
        backup_extention='tar'
    fi
}

directory_backup() {
    check_enable_gzip
    directories=${directories/;/ }
    for directory in ${directories}
    do
        cd $(dirname "$directory")
        directory_basename=$(basename "${directory}")
        backup_name="${backup_date}-${directory_basename}-dir-${backup_suffix}"
        tar -cf "${backup_directory}/${backup_name}.${backup_extention}" "${directory_basename}" ${tar_options} 2> "${backup_error}"
        if [ $? -eq 0 ]
        then
            echo "$(date "+%F %H:%M:%S") [SUCCESS] Backup directory \"${directory}\" completed. Backup name \"${backup_name}.${backup_extention}\"" >> "${backup_logfile}"
        else
            echo "$(date "+%F %H:%M:%S") [ERROR] Backup directory \"${directory}\" failed. Error: \"$(cat ${backup_error})\"" >> "${backup_logfile}"
            mail_subject="${mail_subject}: ${directory}"
            send_email
            rm "${backup_directory}/${backup_name}.${backup_extention}"
        fi
        chmod 600 "${backup_directory}/${backup_name}.${backup_extention}"
    done
}

mysql_backup() {
    check_enable_gzip
    if [ "${db_server}" ]
    then
        db_server="-h${db_server}"
    else
        db_server='-hlocalhost'
    fi
    if [ "${db_username}" ]
    then
        if [ "${db_password}" ]
        then
            mysql_auth="-u${db_username} -p${db_password}"
        else
            mysql_auth="-u${db_username}"
        fi
    fi
    cd "${backup_directory}"
    databases=${databases/;/ }
    for database in ${databases}
    do
        backup_name="${backup_date}-${database}-db-${backup_suffix}"
        mysqldump ${db_server} ${mysql_auth} ${db_backup_options} ${database} > "${backup_name}.sql" 2> "${backup_error}"
        if [ $? -eq 0 ]
        then
            tar -cf "${backup_name}.${backup_extention}" "${backup_name}.sql" ${tar_options}
            chmod 600 "${backup_name}.${backup_extention}"
            echo "$(date "+%F %H:%M:%S") [SUCCESS] Backup database \"${database}\" completed. Backup name \"${backup_name}.${backup_extention}\"" >> "${backup_logfile}"
        else
            echo -e "$(date "+%F %H:%M:%S") [ERROR] Backup database \"${database}\" failed. Error: \"$(cat ${backup_error} | grep -v 'Using a password on the command line interface can be insecure')\"" >> "${backup_logfile}"
            mail_subject="${mail_subject}: ${database}"
            send_email
        fi
        rm "${backup_name}.sql"
    done
}

start_backup() {
    if [ ${directories} ]
    then
        directory_backup
    fi
    if [ ${databases} ]
    then
        mysql_backup
    fi
}

rotate_backup() {
    if [ yes = "${backup_rotation_enabled}" ]
    then
        find -mtime +${backup_rotation} -delete
    fi
}

# Main
main() {
    case ${backup_type} in
        local)
            start_backup
            rotate_backup
        ;;
        nfs)
            mount -t nfs "${backup_server}:${nfs_target}" "${backup_directory}" -o ${nfs_options} 2> "${backup_error}"
            if [ $? -eq 0 ]
            then
                start_backup
                rotate_backup
                cd /tmp
                umount "${backup_directory}"
            else
                echo -e "$(date "+%F %H:%M:%S") [ERROR] Mount \"${backup_server}:${nfs_target}\" via ${backup_type} failed. Error: \"$(cat ${backup_error})\"" >> "${backup_logfile}"
                mail_subject="${mail_subject}: ${backup_type}"
                send_email
            fi
        ;;
        cifs)
            if [ "${backup_server_username}" ]
            then
                if [ "${cifs_options}" ]
                then
                    cifs_options="-o user=${backup_server_username},password=${backup_server_password},${cifs_options}"
                else
                    cifs_options="-o user=${backup_server_username},password=${backup_server_password}"
                fi
            else
                if [ "${cifs_options}" ]
                then
                    cifs_options="-o guest,${cifs_options}"
                else
                    cifs_options="-o guest"
                fi
            fi

            mount -t cifs "//${backup_server}/${cifs_directory}" "${backup_directory}" ${cifs_options} 2> "${backup_error}"
            if [ $? -eq 0 ]
            then
                start_backup
                rotate_backup
                cd /tmp
                umount "${backup_directory}"
            else
                echo -e "$(date "+%F %H:%M:%S") [ERROR] Mount \"//${backup_server}/${cifs_directory}\" via ${backup_type} failed. Error: \"$(cat ${backup_error})\"" >> "${backup_logfile}"
                mail_subject="${mail_subject}: ${backup_type}"
                send_email
            fi
        ;;
        ftp)
            start_backup
            if [ "${backup_server_username}" ]
            then
                ftp_auth="user ${backup_server_username} ${backup_server_username}"
            fi
            ftp -pin "${backup_server}" << EOF
${ftp_auth}
binary
cd ${ftp_directory}
mput ./${backup_date}-*
bye
EOF
            rm ./${backup_date}-*
        ;;
        *)
            echo -e "$(date "+%F %H:%M:%S") [ERROR] Mount failed. Error: \"Backup type ${backup_type} not found\"" >> "${backup_logfile}"
            mail_subject="${mail_subject}: ${backup_type}"
            send_email
        ;;
    esac
}

main

exit 0
