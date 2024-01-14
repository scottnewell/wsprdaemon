#!/bin/bash

###  grape-daemon.sh:  wakes up at every UTC 00:05, creates and uploads Digial RF files of the last 24 hours of WWV IQ recordings

###    Copyright (C) 2024  Robert S. Robinett
###
###    This program is free software: you can redistribute it and/or modify
###    it under the terms of the GNU General Public License as published by
###    the Free Software Foundation, either version 3 of the License, or
###    (at your option) any later version.
###
###    This program is distributed in the hope that it will be useful,
###    but WITHOUT ANY WARRANTY; without even the implied warranty of
###    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
###   GNU General Public License for more details.
###
###    You should have received a copy of the GNU General Public License
###    along with this program.  If not, see <https://www.gnu.org/licenses/>.

shopt -s -o nounset          ### bash stops with error if undeclared variable is referenced

declare    VERSION=${VERSION-0.1}
declare    VERBOSITY=${VERBOSITY-1}     ### default to level 1
declare -r CMD_NAME=${0##*/}
declare -r CMD_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
declare -r CMD_PATH="${CMD_DIR}/${CMD_NAME}"
declare -r CMD_DESCRIPTION="GRAPE WWV IQ uploader"

###  Manage 
declare -r KIWI_STARTUP_DELAY_SECONDS=60   ### When starting the Pi wait this long before checking the Kiwis which may be powering up at the same time.
declare    SYSTEMNCTL_UNIT_FILE_NAME=${0##*/}
declare -r SYSTEMNCTL_SERVICE_NAME=${SYSTEMNCTL_UNIT_FILE_NAME%.*}
           SYSTEMNCTL_UNIT_FILE_NAME=${SYSTEMNCTL_SERVICE_NAME}.service
declare -r SYSTEMNCTL_UNIT_DIR=/lib/systemd/system
declare -r SYSTEMNCTL_UNIT_PATH=${SYSTEMNCTL_UNIT_DIR}/${SYSTEMNCTL_UNIT_FILE_NAME}

declare MINUTES_PER_DAY=$(( 60 * 24 ))
declare GRAPE_TMP_DIR="/tmp/wd_grape_wavs"
declare GRAPE_WAV_ARCHIVE_ROOT_PATH="${HOME}/wsprdaemon/wav-archive.d"
declare WD_SILENT_FLAC_FILE_PATH="${HOME}/wsprdaemon/silent_iq.flac"

function grape_init() {
    if [[ ! -d ${GRAPE_TMP_DIR} ]]; then
        echo "Creating ${GRAPE_TMP_DIR}"
        sudo mkdir ${GRAPE_TMP_DIR}
    fi
    local rc
    mountpoint -q ${GRAPE_TMP_DIR}
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        sudo mount -t tmpfs -o size=6G tmpfs ${GRAPE_TMP_DIR}
    fi
    rm -rf ${GRAPE_TMP_DIR}/*
}

function create_service_file() {
    cat > ${SYSTEMNCTL_UNIT_FILE_NAME} <<EOF
    [Unit]
    Description= ${CMD_DESCRIPTION}
    After=multi-user.target

    [Service]
    User=$(id -u -n)
    Group=$(id -g -n) 
    WorkingDirectory=${CMD_DIR}
    ExecStart=${CMD_PATH} -A
    ExecStop=${CMD_PATH} -z
    Type=forking
    Restart=on-abort

    [Install]
    WantedBy=multi-user.target
EOF
    }

function setup_systemctl_deamon() 
{
    if [[ ! -d ${SYSTEMNCTL_UNIT_DIR} ]]; then
        echo "WARNING: this server appears to not be configured to use 'systemnctl' needed to start the kiwiwspr daemon at startup"
        return
    fi
    if [[ -f ${SYSTEMNCTL_UNIT_PATH} ]]; then
        if diff ${SYSTEMNCTL_UNIT_FILE_NAME} ${SYSTEMNCTL_UNIT_PATH} ; then
            echo "This service is already setup"
            return 0
        else
            echo "This service template ${SYSTEMNCTL_UNIT_FILE_NAME} differs from the installed service file ${SYSTEMNCTL_UNIT_PATH}, so reinstall it."
        fi
    fi
    sudo cp ${SYSTEMNCTL_UNIT_FILE_NAME} ${SYSTEMNCTL_UNIT_PATH}
    echo "Copied ${SYSTEMNCTL_UNIT_FILE_NAME} to ${SYSTEMNCTL_UNIT_PATH}"

    sudo systemctl daemon-reload
    echo "Created '${SYSTEMNCTL_UNIT_PATH}'."
}

function start_systemctl_daemon()
{
    sudo systemctl start ${SYSTEMNCTL_SERVICE_NAME}
}

function enable_systemctl_deamon() 
{
    setup_systemctl_deamon
    sudo systemctl enable ${SYSTEMNCTL_SERVICE_NAME}
    echo "Watchdog daemon will now automatically start after a powerup or reboot of this system"
}

function disable_systemctl_deamon() 
{
    sudo systemctl stop    ${SYSTEMNCTL_SERVICE_NAME}
    sudo systemctl disable ${SYSTEMNCTL_SERVICE_NAME}
}

function get_systemctl_deamon_status()
{
    setup_systemctl_deamon
    sudo systemctl status ${SYSTEMNCTL_UNIT_FILE_NAME}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        echo "${SYSTEMNCTL_UNIT_FILE_NAME} is enabled"
    else
        echo "${SYSTEMNCTL_UNIT_FILE_NAME} is disabled"
    fi
}

function startup_daemon_control()
{
    local action=${1-h}

    case ${action} in
        h)
            echo "usage: -d [a|i|z|s]     setup to be run at startup of this server using the systemctl service (a=start, i=install and enable, z=disable and stop, s=show status"
            ;;
        a)
            start_systemctl_daemon
            ;;
        i)
            enable_systemctl_deamon
            ;;
        z)
            disable_systemctl_deamon
            ;;
        s)
            get_systemctl_deamon_status
            ;;
        *)
            echo "ERROR: action ${action} is invalid"
            ;;
    esac
}

########################################
function daemon()
{
    local startup_delay=${1-0}

    if [[ ${startup_delay} -eq 0 ]]; then
        echo "$(date): daemon() is starting" | tee -a ${KIWI_POWER_WATCH_DAEMON_LOG_FILE}
    else
        echo "$(date): daemon() will start after a delay of ${startup_delay} seconds" | tee -a ${KIWI_POWER_WATCH_DAEMON_LOG_FILE}
        sleep ${startup_delay}
        echo "$(date): daemon() now starting after a delay of ${startup_delay} seconds" | tee -a ${KIWI_POWER_WATCH_DAEMON_LOG_FILE}
    fi

    while true; do
        [[ ${VERBOSITY} -ge 2 ]] && echo "$(date): Checking that all Kiwis are running" >> ${KIWI_POWER_WATCH_DAEMON_LOG_FILE} 

        ### Make sure the IP interface to the Kiwis is active by successfully pinging the router
        local router_ip=${KIWI_BASE_IP}.1
        while ! ping -c 1 ${router_ip} > /dev/null ; do
            echo "$(date): failed to ping router at ${router_ip}, so assume that ethernet interface on this server is down and can't reach the Kiwis even if they are online.  Sleeping 60 seconds and retrying"
            sleep 60;
        done
        
        local kiwi_id
        for kiwi_id in ${KIWI_ID_LIST[@]}; do
            local kiwi_ip="${KIWI_BASE_IP}.${kiwi_id}"
            ##ping -c 1 ${kiwi_ip} > /dev/null
            curl --silent ${kiwi_ip}:8073/status > curl_output.txt
            local ret_code=$?
            if [[ ${ret_code} -eq 0 ]]; then
                [[ ${VERBOSITY} -ge 2 ]] && echo "$(date): 'curl --silent ${kiwi_ip}/status => ${ret_code}, so Kiwi ${kiwi_id} is OK" >> ${KIWI_POWER_WATCH_DAEMON_LOG_FILE} 
            else
                echo "$(date): ERROR: 'curl --silent ${kiwi_ip}/status' => ${ret_code}, so power cycling Kiwi${kiwi_id} for 10 seconds"  >> ${KIWI_POWER_WATCH_DAEMON_LOG_FILE}
                sain_control ${kiwi_id} off
                sleep 10
                sain_control ${kiwi_id} on  
                ### We won't check this Kiwi again for at least 60 seconds, so no need to wait for it to come alive again
            fi
        done
        sleep ${KIWI_POWER_WAIT_SECS}
    done
}

function spawn_daemon()
{
    local startup_delay=$1 

    if [[ -f ${DAEMON_PID_FILE_PATH} ]]; then
        local daemon_pid=$( < ${DAEMON_PID_FILE_PATH}) 
        if ps ${daemon_pid} > /dev/null ; then
            echo "daemon is running with pid = ${daemon_pid}"
            return 0
        else
            echo "daemon pid ${daemon_pid} in ${DAEMON_PID_FILE_PATH} is not active."
            rm ${DAEMON_PID_FILE_PATH}
        fi
    fi
    daemon ${startup_delay} &
    local daemon_pid=$!
    echo ${daemon_pid} > ${DAEMON_PID_FILE_PATH}
    echo "Spawned daemon which has pid ${daemon_pid}"
}

function kill_daemon()
{
    if [[ -f ${DAEMON_PID_FILE_PATH} ]]; then
        local daemon_pid=$( < ${DAEMON_PID_FILE_PATH}) 
        if ps ${daemon_pid} > /dev/null ; then
            kill ${daemon_pid}
            echo "Killed running daemon which had pid = ${daemon_pid}"
        else
            echo "Found daemon pid ${daemon_pid} in ${DAEMON_PID_FILE_PATH} is not active."
        fi
        rm ${DAEMON_PID_FILE_PATH}
    else
        echo "There is no file ${DAEMON_PID_FILE_PATH}, so daemon was not running"
    fi
}

function get_daemon_status()
{
    if [[ -f ${DAEMON_PID_FILE_PATH} ]]; then
        local daemon_pid=$( < ${DAEMON_PID_FILE_PATH}) 
        if ps ${daemon_pid} > /dev/null ; then
            echo "daemon is running with pid = ${daemon_pid}"
        else
            echo "Found daemon pid ${daemon_pid} in ${DAEMON_PID_FILE_PATH} but that pid is not active."
            rm ${DAEMON_PID_FILE_PATH}
        fi
    else
        echo "There is no file ${DAEMON_PID_FILE_PATH}, so daemon is not running"
    fi
}

######### The functions which implment this service daemon follow this line ###############
function grape_get_date_status() {
    local date=$1

    if [[ "${date}" == "h" ]]; then
        echo "usage: -S YYYYMMDD"
        return 0
    fi
    local date_root_dir="${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${date}"

    if [[  ! -d ${date_root_dir} ]]; then
        echo "Can't find ${date_root_dir}"
        return 1
    fi
    local rc=0
    local band_dir_list=( $(find ${date_root_dir} -mindepth 3 -type d) )
    echo "Found ${#band_dir_list[@]} bands for UTC date ${date}"
    for band_dir in ${band_dir_list[@]} ; do
        local flac_file_list=( $( find ${band_dir} -type f -name '*.flac') )
        local silent_flac_file_list=( $( find ${band_dir} -links +1 -type f -name '*.flac') )
        printf "In %-90s found ${#flac_file_list[@]} flac files"  ${band_dir}
        if [[ ${#silent_flac_file_list[@]} -gt 0 ]]; then
            printf ", of which ${#silent_flac_file_list[@]} are silence files"
        fi
        printf "\n"
    done
    return ${rc}
}

function grape_repair_date_wavs() {
    local date=$1
    local hours_list=( $(seq -f "%02g" 0 23) )
    local minutes_list=( $(seq -f "%02g" 0 59) )

    if [[ "${date}" == "h" ]]; then
        echo "usage: -S YYYYMMDD"
        return 0
    fi
    local date_root_dir="${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${date}"
    
    if [[  ! -d ${date_root_dir} ]]; then
        echo "Can't find ${date_root_dir}"
        return 1
    fi
    local band_dir_list=( $(find ${date_root_dir} -mindepth 3 -type d) )
    echo "Found ${#band_dir_list[@]} bands"
    for band_dir in ${band_dir_list[@]} ; do
        local flac_file_list=( $( find ${band_dir} -type f -name '*.flac') )
        if [[ ${#flac_file_list[@]} -eq ${MINUTES_PER_DAY} ]]; then
            echo "Found ${#flac_file_list[@]} flac files in ${band_dir}"
        else
            # read -p "Found only ${#flac_file_list[@]} flac files in ${band_dir} so it needs repair. Press <RETURN}> to repair all missing flac files in this directory => "
            local band_freq=${flac_file_list[0]##*/}
                  band_freq=${band_freq#*_}
                  band_freq=${band_freq/_iq.flac/}
            local hour
            for hour in ${hours_list[@]} ; do
                local minute 
                for minute in ${minutes_list[@]} ; do
                    local expected_file_name="${date}T${hour}${minute}00Z_${band_freq}_iq.flac"
                    local expected_file_path=${band_dir}/${expected_file_name}
                    if [[ ! -f ${expected_file_path} ]]; then
                        [[ ${VERBOSITY} -ge 2 ]] && echo "Can't find expected IQ file ${expected_file_path}, so link the 1 minute of silence file in its place"
                        #read -p "Press <RETURN> to create it from ${WD_SILENT_FLAC_FILE_PATH} .flac: "
                        ln ${WD_SILENT_FLAC_FILE_PATH}  ${expected_file_path}
                    fi
                done
            done
        fi
    done
}

### Give a DATE...BAND directory which has the requried 1440 minute flac files. create a single w4 hour long 10 Hz BW wav file
function create_grape_wav_file()
{
    local flac_file_dir=$1

    local output_10sps_wav_file="${flac_file_dir}/24_hour_10sps_iq.wav"
    if [[ -f ${output_10sps_wav_file} ]]; then
        [[ ${VERBOSITY} -gt 1 ]] && echo "create_grape_wav_file(): the 10 sps wav file ${output_10sps_wav_file} exists, so there is nothing to do in this directory"
        return 0
    fi

    local flac_file_list=( $(find ${flac_file_dir} -type f -name '*.flac' -printf '%p\n' | sort ) )   ### sort the output of find to ensure the array elements are in time order

    if [[ ${TEST_ARRAY_ORDER-no} == "yes" ]]; then
        ( IFS=$'\n' ; echo "${flac_file_list[*]}" > flac_file_list.txt )
        local i
        for (( i = 0; i <  ${#flac_file_list[@]}; ++i )) ; do
            printf "%4d: %s\n" $i ${flac_file_list[i]}
        done | less
    fi
    if [[ ${#flac_file_list[@]} -ne ${MINUTES_PER_DAY}  ]]; then
        echo "create_grape_wav_file(): ERROR: found only ${#flac_file_list[@]} flac files in ${flac_file_dir}, not the expected ${MINUTES_PER_DAY} files"
        return 1
    fi
    [[ ${VERBOSITY} -gt 2 ]] && echo "create_grape_wav_file(): create one 24 hour, 10 hz wav file from ${#flac_file_list[@]} flac files"
    mkdir -p ${GRAPE_TMP_DIR}
    rm -f ${GRAPE_TMP_DIR}/*

    local rc
    nice -n 19 flac -s --output-prefix=${GRAPE_TMP_DIR}/ -d ${flac_file_list[@]}
     rc=$?
    rc=0
    if [[ ${rc} -ne 0 ]]; then
        echo "create_grape_wav_file(): ERROR: 'flac ...' => ${rc} "
        rm -f  ${GRAPE_TMP_DIR}/*
        return ${rc}
    fi

    local wav_files_list=( ${flac_file_list[@]##*/} )            ### Chops off the paths
    wav_files_list=( ${wav_files_list[@]/#/${GRAPE_TMP_DIR}/} )  ### Prepends the path to the temp directory
    wav_files_list=( ${wav_files_list[@]/.flac/.wav} )           ### replaces the filename extension .flac with .wav

    ulimit -n 2048    ### sox will open 1440+ files, so up the open file limit
    nice -n 19 sox ${wav_files_list[@]} ${output_10sps_wav_file} rate 10
    rc=$?
    rm  ${wav_files_list[@]}
    if [[ ${rc} -ne 0 ]]; then
        echo "create_grape_wav_file(): ERROR: 'sox ...' => ${rc} "
         return ${rc}
    fi
    [[ ${VERBOSITY} -gt 1 ]] && echo "create_grape_wav_file(): created ${output_10sps_wav_file}"
}

### '-C' verify or create a 24 hour 10 hz bw wav file for each band 
function grape_create_24_hour_wavs() {
    local date=$1

    if [[ "${date}" == "h" ]]; then
        echo "usage: -s yyyymmdd"
        return 0
    fi
    local date_root_dir="${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${date}"

    if [[  ! -d ${date_root_dir} ]]; then
        echo "can't find ${date_root_dir}"
        return 1
    fi
    local rc=0
    local band_dir_list=( $(find ${date_root_dir} -mindepth 3 -type d -printf '%p\n' | sort) )
    echo "found ${#band_dir_list[@]} bands"
    for band_dir in ${band_dir_list[@]} ; do
        echo "create 24 hour wav file in ${band_dir}"
        create_grape_wav_file ${band_dir}
    done
    return 0
}

### '-p' 
function grape_purge_all_empty_date_trees(){
    local wav_archive_dates_dir_list=( $(find ${GRAPE_WAV_ARCHIVE_ROOT_PATH} -mindepth 1 -maxdepth 1 -type d -printf '%p\n' | sort)  )
    local wav_archive_date
    for wav_archive_date in ${wav_archive_dates_dir_list[@]##*/} ; do
        local date_files_list=( $( find ${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${wav_archive_date} -type f ) )
        if [[ ${#date_files_list[@]} -eq 0 ]]; then
            echo "Purging empty date  tree ${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${wav_archive_date}"
            rm -r ${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${wav_archive_date}
        else
            printf  "Found %5d files in ${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${wav_archive_date}\n" ${#date_files_list[@]}
        fi
    done
}

### '-t' 
function grape_show_all_dates_status(){
    local wav_archive_dates_dir_list=( $(find ${GRAPE_WAV_ARCHIVE_ROOT_PATH} -mindepth 1 -maxdepth 1 -type d -printf '%p\n' | sort)  )
    local wav_archive_date
    for wav_archive_date in ${wav_archive_dates_dir_list[@]##*/} ; do
        grape_get_date_status ${wav_archive_date}
    done
}

### '-r' 
function grape_repair_all_dates_wavs()
{
    local current_date
    TZ=UTC printf -v current_date "%(%Y%m%d)T"
    local wav_archive_dates_dir_list=( $(find ${GRAPE_WAV_ARCHIVE_ROOT_PATH} -mindepth 1 -maxdepth 1 -type d -printf '%p\n' | sort)  )
    local wav_archive_date
    for wav_archive_date in ${wav_archive_dates_dir_list[@]##*/} ; do
        if [[ ${wav_archive_date} ==  ${current_date} ]] ; then
            echo "Skipping grape_repair_date_wavs for current UTC day ${current_date}"
        else
            grape_repair_date_wavs ${wav_archive_date}
        fi
    done
}


### '-U'  Runs rsync to upload all the 24_hour_10sps_iq.wav wav files to the grape user account at wsprdaemon.org
function grape_upload_all_10hz_wavs() {
    restore_all_dates
    ( cd ~/wdprdaemon; rsync -avP --exclude=*.flac --include=24_hour_10sps_iq.wav  wav-archive.d/ grape@wsprdaemon.org:wav-archive.d/ )
}    

function grape_print_usage()
{
    echo "$0 Version ${VERSION}: 
    -c YYYYMMDD      Create 10 sps wav files for each band from flac.tar files for YYYYMMDD
    -a               Start daemon which pings kiwis and power cycles them if they don't respond
    -A               start daemon with a delay of ${KIWI_STARTUP_DELAY_SECONDS}
    -z               kill the daemon
    -s               show the daemon status
    === Internal and diagnostic commands =====
    -C YYYYMMDD      Create 24 hour 10 Hz wav files for all bands 
    -S YYYYMMDD      Show the status of the files in that tree
    -R YYYYMMDD      Repair the directory tree by filling in missing minutes with silent_iq.flac
    -p               Purge all empty date trees
    -r               Repair all date trees
    -t               Show status of all the date trees
    -U               Upload all of the local 24_hour_10sps_iq.wav files to the grape@wsprdaemon.org account
    -d [a|i|z|s]     systemctl commands for daemon (a=start, i=install and enable, z=disable and stop, s=show status"
}

function grape_menu() {
    case ${1--h} in
        -c)
            grape_data_upload  ${2-h}
            ;;
        -C)
            grape_create_24_hour_wavs ${2-h}
            ;;
        -S)
            grape_get_date_status ${2-h}
            ;;
        -R)
            grape_repair_date_wavs ${2-h}
            ;;
        -p)
            grape_purge_all_empty_date_trees
            ;;
        -t)
            grape_show_all_dates_status
            ;; 
        -r) 
            grape_repair_all_dates_wavs
            ;;
        -U)
            grape_upload_all_10hz_wavs
            ;;
        -a)
            spawn_daemon ${2-0}
            ;;
        -A)
            ### If this is installed as a Pi daemon by '-d a', the systemctl system will execute '-A'.  
            spawn_daemon ${KIWI_STARTUP_DELAY_SECONDS}
            ;;
        -z)
            kill_daemon
            ;;
        -s)
            get_daemon_status
            ;;
        -d)
            startup_daemon_control ${2-h}
            ;;
        -h)
            grape_print_usage
            ;;
        *)
            echo "ERROR: flag '$1' is not valid"
            ;;
    esac
}

grape_init
grape_menu $@

exit 0
