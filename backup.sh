#!/bin/bash
#  
#  Copyright 2017 Oleg Dolgikh <aristarkh@aristarkh.net>
#  
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation version 3.
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

working_dir=$(dirname $0)
source "${working_dir}/backup.conf"

# Functions
send_email() {
    if [ yes = "${enable_mail_notification}" ]
    then
        send_command="sendemail -f ${mail_from} -t ${mail_to} -u ${mail_subject} -s ${mail_server}"
        cat ${backup_error} | ${send_command}
    fi
}

directory_backup() {
    if [ yes = "${enable_gzip}" ]
    then
        tar_options="--gzip ${tar_options}"
        backup_extention='tar.gz'
    else
        backup_extention='tar'
    fi

    cd "${backup_directory}"
    directories=${directories/;/ }
    for directory in ${directories}
    do
        backup_name="${backup_date}-$(basename ${directory})-${backup_suffix}"
        tar -cf "${backup_name}.${backup_extention}" "${directory}" ${tar_options} 2> "${backup_error}"
        if [ $? -eq 0 ]
        then
            echo "$(date "+%F %H:%M:%S") [SUCCESS] Backup directory \"${directory}\" completed. Backup name \"${backup_name}.${backup_extention}\"" >> "${backup_logfile}"
        else
            echo "$(date "+%F %H:%M:%S") [ERROR] Backup directory \"${directory}\" failed. Error: \"$(cat ${backup_error})\"" >> "${backup_logfile}"
            mail_subject="${mail_subject}: ${directory}"
            send_email
            rm "${backup_name}.${backup_extention}"
        fi
        chmod 600 "${backup_name}.${backup_extention}"
    done
}

mysql_backup() {
    backup_extention='tar.gz'
    if [ "${db_username}" ]
    then
        mysql_auth="-u${db_username} -p${db_password}"
    fi
    cd "${backup_directory}"
    databases=${databases/;/ }
    for database in ${databases}
    do
        backup_name="${backup_date}-${database}-${backup_suffix}"
        mysqldump ${mysql_auth} ${dump_options} ${database} > "${backup_name}.sql" 2> "${backup_error}"
        if [ $? -eq 0 ]
        then
            tar -czf "${backup_name}.${backup_extention}" "${backup_name}.sql"
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

# Main
main() {
    case ${backup_type} in
        local)
            start_backup
            find -mtime +${backup_rotation} -delete
        ;;
        nfs)
            mount -t nfs "${backup_server}:${nfs_target}" "${backup_directory}" -o ${nfs_options} 2> "${backup_error}"
            if [ $? -eq 0 ]
            then
                start_backup
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
