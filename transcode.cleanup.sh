#!/bin/bash
# ! /bin/sh

SCRIPT_DIR=/config/ffmpeg
TRANSCODES_DIR=/config/transcodes
SEMAPHORE_DIR=/config/semaphore # use RAM drive for FFMPEG transcoding PID and PAUSE files
LOG_DIR=/config/log
CLEANUP_LOG=$LOG_DIR/transcode.cleanup.log # create a single log file (easier when using OFF, WARN or INFO level logging)
CLEANUP_LOG_MAXSIZE=10485760 # maximum size of the log file reaching which the log file will be truncated (default is 10485760 bytes=10 MB)
#SEMAPHORE_DIR=$SCRIPT_DIR/log # use mounted directory on host machine for easier access
#LOG_DIR=$SCRIPT_DIR/log
#CLEANUP_LOG=$LOG_DIR/transcode.cleanup.$$.log # create separate log file per each cleanup wrap trigger (easier for DEBUG or TRACE level logging)
CLEANUP_PID=$SEMAPHORE_DIR/transcode.cleanup.pid
CLEANUP_CMD_EXIT=$SEMAPHORE_DIR/transcode.cleanup.stop # flag file instructing that cleanup script must shutdown
CLEANUP_SHUTDOWN=$SEMAPHORE_DIR/transcode.cleanup.stopping # flag file informing that cleanup script is shutting down
CLEANUP_STOPPED=$SEMAPHORE_DIR/transcode.cleanup.stopped # flag file informing that cleanup script has been shut down

#
# 0 - OFF    No logging (log file is not created)
# 1 - WARN   Log warnings (very few occurences)
# 2 - INFO   Log few most important events (deletion of files)
# 3 - DEBUG  Log explanatory messages
# 4 - TRACE  Log commands executed during processing and their output
#
CLEANUP_LOG_LEVELS=(O W I D T)         # prefix log entries to notify about log level
CLEANUP_LOG_LEVEL_NAMES=(OFF WARN INFO DEBUG TRACE)
CLEANUP_LOG_LEVEL=$1                   # 0 - OFF | 1 - WARN | 2 - INFO | 3 - DEBUG | 4 - TRACE
CLEANUP_LOG_TIMESTAMP=$2               # 1 - log entries will be prefixed with timestamp | 0 - log entries without timestamp
CLEANUP_INACTIVITY_SHUTDOWN_SECONDS=3600 # seconds of inactivity when no PID file is found after which the cleanup script will exit (default: 3600 = 1 hour)
CLEANUP_ALL_WHEN_SPACE_REACHES_PERC=98 # when used space is at least this number % of total space then delete most of TS files (default: 98)
CLEANUP_ALL_KEEP_TS_MOD_SECONDS=1      # when deleting most of TS files to free up space, do not delete files which where modified less than this num of sec before
# allowed space will be calculated per each Segment ID
#CLEANUP_WHEN_SPACE_REACHES_PERC=35     # when used space is at least this number % of total space then delete TS files keeping few subsequent by TS ID
FFMPEG_WRAP_PAUSE_PERC=10              # FFMPEG WRAP will be paused (SIGSTOP) when space used by TS files takes up this much % of total space
FFMPEG_POS_TIME_STALL=3                # if TS file won't be created within this number of seconds since last FFMPEG position change then FFMPEG will be resumed even if it runs over allowed space
NO_SPACE_LM_FILE_COUNT=5               # when no space left in transcodes directory, this is number of last modified TS files to keep in array (potentially corrupted)
# cannot keep min number of subsequent files - for each Segment ID there will be different allowed space, and files will be kept based on consumed space
#KEEP_MIN_SEQUENTIAL_TS_COUNT=6         # when no space left, this is number of minimum TS files to keep after Last Accessed TS file, rest will be deleted (use -1 to keep all sequential TS files)
TS_SPACE_ALLOWED_PERC_DEFAULT=70       # this is the default % of used space allowed per Segment ID (it is used before calculation based on number of Segment IDs)
TS_SPACE_RESERVED_MIN_DIVIDER=3        # this is minimum divider - used when PID count is less than this number to determine the reserved size of directory space (for possible next TS segment)
TS_SPACE_RESERVED_MAX_DIVIDER=0        # this is maximum divider - used to specify count of parallel playbacks for optimal space usage (default 0 means infinite count)
                                       # For example, if specify 2 then 95% of transcoding directory space will be split in half for 2 TS segments (minimum reserved space of 5% is still
                                       #              required for tolerable space calculation and 5% additional for any other files, but there is not enough reseve
                                       #              for possible next TS segment) if 3rd client is starting playback then there will not be enough space for any playback and
                                       #              latest TS files will get deleted, however when 3rd playback is started then this variable will be ignored and space will be
                                       #              calculated for 3 TS segments
TS_TOLERABLE_SPACE_OVERRUN_PERC=3      # this is the additional allowed (tolerable) space when allowed space is exceeded by TS files sizes
TS_INACTIVITY_RESTART_SECONDS=15       # FFMPEG will be restarted and TS files deleted when PID and TS files exist, but no file is accessed by client for this number of seconds
KEEP_TS_MOD_SECONDS=1                  # number of seconds after Last Modified Date/Time when TS files will not be deleted
KEEP_PID_MOD_SECONDS=30                # number of seconds after Last Modified Date/Time when PID files will not be deleted
TRANSCODES_DIR_ESCAPED=${TRANSCODES_DIR//\//\\\/} # convert "/config/transcodes" to "\/config\/transcodes"
#SCHEDULE_RESTART_FFMPEG_TS_ID_COUNT=5  # number of segments left till scheduled restart of FFMPEG process
SCHEDULE_RESTART_FFMPEG_TS_ID_COUNT=2  # number of segments left till scheduled restart of FFMPEG process - 2 is default value, because
                                       # Jellyfin checks for existance of the next two TS files following after currently buffered (Last Accessed) and
                                       # if the second file does not exist then it checks if FFMPEG process is running, further there are two cases:
                                       # a) FFMPEG process is running - client playback will stall because there is only one file after currently buffered (buffering of last one will not start)
                                       # b) FFMPEG process is not running - Jellyfin will start new FFMPEG process to generate TS files starting with the missing one
                                       # Example: 20 21 22 23
                                       #             ^^ (currently buffered)
                                       #          If we specify value 2 for this variable and TS ID=24 was deleted, TS ID=21 is currently buffered then
                                       #          FFMPEG process will be killed by this script when TS ID=22 will be buffered (deleted file - 2 files).
                                       #          Jellyfin will immediately start new FFMPEG process to create TS ID=24 and playback will continue without interruption.
SCHEDULE_RESUME_FFMPEG_TS_ID_COUNT=3   # number of segments left till scheduled resume of FFMPEG process
DEFAULT_LA_BUFFER_TIME=6               # default=6. Last x TS segment rotation times (time required to buffer till next TS file is accessed by player) for avg calculation
#DEFAULT_FFMPEG_RESTART_TIME=25         # default=25. Last x FFMPEG restart times for avg calculation
SEGMENT_LA_BUFF_STAT_SIZE=3            # how many entries will be stored to calculate average statistics (for array SEGMENT_LA_BUFF_TIME_STAT and SEGMENT_LA_BUFF_SIZE_STAT)
SEGMENT_LA_BUFF_SIZE_STAT_RESET_PERC=25 # what % increase in buffering size will trigger re-set of stored statistics values (for array SEGMENT_LA_BUFF_TIME_STAT and SEGMENT_TS_SIZE_STAT)
#SEGMENT_TS_SIZE_STAT_SIZE=6            # how many entries will be stored to calculate average statistics (for array SEGMENT_LA_BUFF_TIME_STAT and SEGMENT_TS_SIZE_STAT)
#SEGMENT_TS_SIZE_STAT_RESET_PERC=25     # what % increase in TS file size will trigger re-set of stored statistics values (for array SEGMENT_TS_SIZE_STAT)
#SEGMENT_FFMPEG_RESTART_TIME_STAT_SIZE=3 # how many entries ("x") will be stored to calculate average statistics (for array SEGMENT_FFMPEG_RESTART_TIME_STAT)
REMOVE_UNUSED_SEGMENTS_INTERVAL=3600   # interval in seconds to clean-up unused Segment IDs from runtime arrays (3600 seconds = 1 hour)
CLEANUP_DELETED_FILES_INTERVAL=1800    # interval in seconds to clean-up deleted TS files which still hold up space in transcoding directory (1800 seconds = 30 minutes)
CLEANUP_DELETED_FILES_ACC_SECONDS=900  # seconds since deleted file was last accessed before it is deleted during maintenance task (900 seconds = 15 minutes)
CLEANUP_ABENDONED_PROCESSES_INTERVAL=30 # interval in seconds to clean-up abendoned and sleeping FFMPEG processes (having process state = T)
TS_AVG_SIZE_DEFAULT=30000000           # assume this default TS file average size in bytes when statistics are not yet collected for a Segment ID
DATE_FORMAT="%F %T.%9N"                # this format should match to the format that is returned by stat, ls and other commands
#
# Load from file
#
# IMPORTANT! Function remove_unused_segments uses $MAINTAINED_ARRAYS - it must be updated when new array is declared
#            The function will remove elements from the array that have name of old unused Segment IDs
#
# add "SEGMENT_LA_BUFF_TIMESTAMP_ARRAY" if used
MAINTAINED_ARRAYS=("SEGMENT_LA_BUFF_TIME_STAT" \
                   "SEGMENT_LA_BUFF_SIZE_STAT" \
                   "SEGMENT_LA_BUFF_TIME_ARRAY" \
                   "SEGMENT_TS_SIZE_STAT" \
                   "SEGMENT_LA_TS_ID_ARRAY" \
                   "SEGMENT_INACTIVE_TIME_ARRAY" \
                   "SEGMENT_LAST_POS_CHANGE" \
                   "SCHEDULE_RESTART_FFMPEG_FOR_TS_ID" \
                   "SCHEDULE_RESUME_FFMPEG_FOR_TS_ID" \
                  ) # "SEGMENT_FFMPEG_RESTART_TIME_STAT")
#declare -A SEGMENT_LA_BUFF_TIMESTAMP_ARRAY         # key-value pairs, where key is Segment ID and value is last time of buffering TS file as date/time timestamp
declare -A SEGMENT_LA_BUFF_TIME_ARRAY        # key-value pairs, where key is Segment ID and value is last time of buffering TS file in seconds
declare -A SEGMENT_LA_BUFF_TIME_STAT         # key-value pairs, where key is Segment ID and value is array of x last TS segment rotation times
declare -A SEGMENT_LA_BUFF_SIZE_STAT
declare -A SEGMENT_TS_SIZE_STAT              # key-value pairs, where key is Segment ID and value is array of x last TS segment file sizes
declare -A SEGMENT_LA_TS_ID_ARRAY            # key-value pairs, where key is Segment ID and value is last accessed TS ID
declare -A SEGMENT_INACTIVE_TIME_ARRAY       # key-value pairs, where key is Segment ID and value is last time of no buffering of TS files
declare -A SEGMENT_LAST_POS_CHANGE           # key-value pairs, where key is Segment ID and value is last registered playback position change
#declare -A SEGMENT_FFMPEG_RESTART_TIME_STAT  # key-value pairs, where key is Segment ID and value is array of x last FFMPEG restart times
declare -A SCHEDULE_RESTART_FFMPEG_FOR_TS_ID # key-value pairs, where key is Segment ID and value is TS_ID which was deleted
#declare -A SEGMENT_FFMPEG_RESUME_TIME_STAT   # key-value pairs, where key is Segment ID and value is array of x last FFMPEG resume times
declare -A SCHEDULE_RESUME_FFMPEG_FOR_TS_ID  # key-value pairs, where key is Segment ID and value is TS_ID which was paused
#
# Following arrays are re-defined in every loop
#
declare -A TS_SPACE_ALLOWED_PERC_ARRAY
declare -A TS_SPACE_TOLERABLE_PERC_ARRAY
#
# Reset bash script configuration
#
SECONDS=0 # reset timer
REMOVE_UNUSED_SEGMENTS_LAST=$SECONDS           # Store last time when clean-up was performed
USER_ID=$(id -u)                               # USER_ID is used for tracking if script is run by ROOT user
CLEANUP_DELETED_FILES_LAST=$((SECONDS + 1800)) # Store last time when clean-up was performed (first maintenance after 1800 seconds = 30 minutes)
CLEANUP_ABENDONED_PROCESSES_LAST=$SECONDS      # Store last time when clean-up was performed
TS_SPACE_ALLOWED=
TS_SPACE_ALLOWED_PERC=$TS_SPACE_ALLOWED_PERC_DEFAULT
[ "$CLEANUP_LOG_LEVEL" != "" ] || CLEANUP_LOG_LEVEL=0         # set to default (OFF) if not configured
[ "$CLEANUP_LOG_TIMESTAMP" != "" ] || CLEANUP_LOG_TIMESTAMP=0 # set to default if not configured
CLEANUP_INACTIVITY_SHUTDOWN_COUNTER=-1 # deactivate
CLEANUP_LOG_MAXSIZE_COUNTER=$SECONDS # time counter to check log file size at hardcoded interval (5 minutes)
#
# $1 log level (1 to 4) - message will be logged only if CLEANUP_LOG_LEVEL is equal or higher than the $1
# $2 log message
#
function log {
    if [ $CLEANUP_LOG_LEVEL -ge $1 ]; then
        if [ $CLEANUP_LOG_TIMESTAMP -eq 1 ]; then                           # log with timestamp
            echo "${CLEANUP_LOG_LEVELS[$1]} $(date +"$DATE_FORMAT") [$$] $2" >> $CLEANUP_LOG;
        else
            echo "[$$] $2" >> $CLEANUP_LOG;
        fi
    fi
}

function log_warn {
    log 1 "$1"
}

function log_info {
    log 2 "$1"
}

function log_debug {
    log 3 "$1"
}

function log_trace {
    log 4 "$1"
}

function trace_is_on {
    [ $CLEANUP_LOG_LEVEL -ge 4 ]
    return
}

function debug_is_on {
    [ $CLEANUP_LOG_LEVEL -ge 3 ]
    return
}

function info_is_on {
    [ $CLEANUP_LOG_LEVEL -ge 2 ]
    return
}

function log_print_config {
    log_info "--------------------------------------------------------------------------------"
    log_info "Starting Transcoding clean-up process"
    log_info ""
    log_info "Configuration:"
    log_info "                          SCRIPT_DIR: $SCRIPT_DIR"
    log_info "                      TRANSCODES_DIR: $TRANSCODES_DIR"
    log_info "                       SEMAPHORE_DIR: $SEMAPHORE_DIR"
    log_info "                         CLEANUP_PID: $CLEANUP_PID"
    log_info "                         CLEANUP_LOG: $CLEANUP_LOG"
    log_info "                   CLEANUP_LOG_LEVEL: $CLEANUP_LOG_LEVEL (${CLEANUP_LOG_LEVEL_NAMES[$CLEANUP_LOG_LEVEL]})"
    log_info "              FFMPEG_WRAP_PAUSE_PERC: $FFMPEG_WRAP_PAUSE_PERC"
    log_info " CLEANUP_ALL_WHEN_SPACE_REACHES_PERC: $CLEANUP_ALL_WHEN_SPACE_REACHES_PERC"
    #log_info "     CLEANUP_WHEN_SPACE_REACHES_PERC: $CLEANUP_WHEN_SPACE_REACHES_PERC"
    log_info "              NO_SPACE_LM_FILE_COUNT: $NO_SPACE_LM_FILE_COUNT"
    #log_info "        KEEP_MIN_SEQUENTIAL_TS_COUNT: ${KEEP_MIN_SEQUENTIAL_TS_COUNT}$(if [ $KEEP_MIN_SEQUENTIAL_TS_COUNT -eq -1 ]; then echo ' (keep all)'; fi)"
    log_info "                 KEEP_TS_MOD_SECONDS: $KEEP_TS_MOD_SECONDS"
    log_info "                KEEP_PID_MOD_SECONDS: $KEEP_PID_MOD_SECONDS"
    log_info ""
    if [ $USER_ID -eq 0 ]; then
        log_warn "WARNING: RUNNING SCRIPT UNDER ROOT USER. FILES WITHOUT READ PERMISSION WHICH WERE CREATED BY JELLYFIN USER ARE NOT ACCESSIBLE FOR ROOT."
    fi
}
log_print_config

#
# Decomposes given argument into global variables
# $1 - line containing Last Accessed, Last Modified, File size, Filename
#      (eg, 2023-02-02 22:33:37.234998714 +0000 2023-02-02 22:33:29.095998604 +0000 23018532 ./572f0e503dcbc2ea18bff03a55e2162610.ts)
#
# ACC_DATE - Last Accessed Date
# ACC_TIME - Last Accessed Time
# MOD_DATE - Last Modified Date
# MOD_TIME - Last Modified Time
# FILESIZE - File size in bytes
# FILENAME - Filename (may include path)
#
function decompose_file_xysn {
    t=$1
    ACC_DATE=${t%% *}; t=${t#* }
    ACC_TIME=${t%% *}; t=${t#* }
    t=${t#* } # ignore +0000
    MOD_DATE=${t%% *}; t=${t#* }
    MOD_TIME=${t%% *}; t=${t#* }
    t=${t#* } # ignore +0000
    FILESIZE=${t%% *}; t=${t#* }
    FILENAME=${t%% *}
}

#
# Decomposes given argument into global variables
# $1 - line containing Filename, Last Accessed, Last Modified
#      (eg, ./572f0e503dcbc2ea18bff03a55e2162610.ts 2023-02-02 22:33:37.234998714 +0000 2023-02-02 22:33:29.095998604 +0000)
#
# ACC_DATE - Last Accessed Date
# ACC_TIME - Last Accessed Time
# MOD_DATE - Last Modified Date
# MOD_TIME - Last Modified Time
# FILENAME - Filename (may include path)
#
function decompose_file_nxy {
    t=$1
    FILENAME=${t%% *}; t=${t#* }
    ACC_DATE=${t%% *}; t=${t#* }
    ACC_TIME=${t%% *}; t=${t#* }
    t=${t#* } # ignore +0000
    MOD_DATE=${t%% *}; t=${t#* }
    MOD_TIME=${t%% *}; t=${t#* }
}

#
# Decomposes given argument into global variables
# $1 - line containing Filename, Size, Last Accessed, Last Modified
#
function decompose_file_nsxy {
    t=$1
    FILENAME=${t%% *}; t=${t#* }
    FILESIZE=${t%% *}; t=${t#* }
    ACC_DATE=${t%% *}; t=${t#* }
    ACC_TIME=${t%% *}; t=${t#* }
    t=${t#* } # ignore +0000
    MOD_DATE=${t%% *}; t=${t#* }
    MOD_TIME=${t%% *}; t=${t#* }
}

#
# Decomposes given argument into global variables
# $1 - line containing Last Modified, Filename
#
function decompose_file_yn {
    t=$1
    MOD_DATE=${t%% *}; t=${t#* }
    MOD_TIME=${t%% *}; t=${t#* }
    t=${t#* } # ignore +0000
    FILENAME=${t%% *};
}

#
# Decomposes given argument into global variables
# $1 - line containing Last Modified (milliseconds), Filename
#
function decompose_file_Yn {
    t=$1
    MOD_MILLIS=${t%% *}; t=${t#* }
    FILENAME=${t%% *};
}

#
# $1 - filepath to retrieve modification date/time
#
# Usage: if get_file_mod_date test.txt; then
#           echo "File modified at: $MOD_DATE $MOD_TIME"
#        else
#           echo "File not found"
#        fi
#
function get_file_mod_date {
    t=$(stat -c '%y' $1 2>&1) # 2>&1 - error to stdout
    if [ "${t:0:5}" == "stat:" ]; then # stat: cannot statx 'test.txt': No such file or directory
        [ 1 != 1 ] # return false
    else
        MOD_DATE=${t%% *}; t=${t#* }
        MOD_TIME=${t%% *} # return true
    fi
}

#
# $1 - Segment ID (eg, 036975d222b737b6f47a82ac186e5d47)
# $2 - TS filepath (eg, /config/transcodes/036975d222b737b6f47a82ac186e5d47251.ts)
#                                          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
# $TS_ID will contain TS file ID
#
function extract_ts_id {
    [[ "$2" =~ .*$1([0-9]+).ts ]]
    TS_ID=${BASH_REMATCH[1]}
}

#
# Returns date/time difference in seconds comparing two date/time
# $1 - date/time to compare (earlier time)
# $2 - date/time to compare (later time)
#
# Result is returned in DIFF_SECONDS
#
# Example: datetime_diff "2023-02-11 17:27:48.019751128 +0000" "2023-02-11 17:28:02.300751321 +0000"
#          echo $DIFF_SECONDS
#          14
#
function datetime_diff {
    DIFF_SECONDS=$(( $(date -d "$2" "+%s") - $(date -d "$1" "+%s") ))
}

#
# Returns date/time difference in seconds comparing to current date/time
# $1 - date/time to compare
#
# Result is returned in DIFF_SECONDS
#
# Example: datetime_diff "2023-02-11 17:28:02.300751321 +0000"
#          echo $DIFF_SECONDS
#          14917
#
function datetime_diff_now {
    DIFF_SECONDS=$(( $(date "+%s") - $(date -d "$1" "+%s") ))
}

#
# $1 date/time in any supported format by "date" command
# $2 number of seconds to deduct from $1
#
# Returns date/time with added (or deducted if negative) x number of seconds in format: $DATE_FORMAT
# Returns new value in global variable $DATE_TIME
# Example: "2023-02-11 17:28:02.300751321"
#
function datetime_add_seconds {
    DATE_TIME=$(date -d "$1 $2 sec" +"$DATE_FORMAT")
}

#
# $1 date/time in any supported format by "date" command
# $2 number of seconds to deduct from $1
#
# Returns milliseconds with added (or deducted if negative) x number of seconds in format: nnn.fff
# Returns new value in global variable $MILLIS
# Example: 1676136482.300751321 to 1676136481.300751321
#
function millis_add_seconds {
    MILLIS="$(( ${1%%.*}$2 )).${1##*.}"
}

#
# $1 date/time in any supported format by "date" command
#
# Returns representation of date/time in milliseconds using "echo".
# Example: "2023-02-11 17:28:02.300751321 +0000" to 1676136482.300751321
#
function date_to_millis {
    echo $(date -d "$1" "+%s.%N")
}

#
# $1 milliseconds (format nnn.fff)
#
# Returns representation of milliseconds in date/time using "echo".
# Example: 1676136482.300751321 to "2023-02-11 17:28:02.300751321 +0000"
#
function millis_to_date {
    echo $(date -d @$1 +"$DATE_FORMAT")
}

#
# Test if $1 argument is found in array specified in $2 argument
# Example: if elementInArr "$test" "${LM_FILES_ARRAY[@]}"; then
#
#function elementInArr {
#	local e match="$1"
#	shift
#	for e; do [[ "$e" == "$match" ]] && return 0; done
#	return 1
#}

#
# Test whether the value is present in an array
#
# Example:
#          if value "test" in array; then echo exists; fi
#
function value {
    if [ "$2" != in ]; then
        echo "Incorrect usage."
        echo "Correct usage: value {value} in {array}"
        return
    fi   
    local e match="$1"
    for e in $(eval 'echo ${'$3'[@]}'); do [[ "$e" == "$match" ]] && return 0; done
    return 1
}


#
# Tests if filepath specified in $1 argument is found in $LM_FILES_ARRAY
# LM_FILES_ARRAY represents 5 last modified files when there is no free space left in transcodes directory
#
function is_in_lm_files_array {
    #elementInArr "$1" "${LM_FILES_ARRAY[@]}"
    [ value "$1" in LM_FILES_ARRAY ]
    return $?
}

#
# $1 - Segment ID
#
# Returns FFMPEG WRAP PID from PID file into variable $FFMPEG_WRAP_PID
#
function get_ffmpeg_pid {
    local segment_id=$1
    log_trace "#READ PID# head -1 $SEMAPHORE_DIR/${segment_id}.pid"
    if trace_is_on; then head -1 $SEMAPHORE_DIR/${segment_id}.pid >> $CLEANUP_LOG 2>&1; echo "#" >> $CLEANUP_LOG; fi;
    FFMPEG_WRAP_PID=$(head -1 $SEMAPHORE_DIR/${segment_id}.pid)
    if [[ "$FFMPEG_WRAP_PID" == "" ]]; then
        log_warn "FFMPEG WRAP PID file is empty. Terminating clean-up process."
#
# TODO: DELETE ALL TS FILES AND KILL ALL *FFMPEG* CHILD PROCESSES - GLOBAL RESTART
#       FFMPEG processes are listed with "ps" command where process name is FFMPEG WRAP
#
        exit
    fi
}

#
# $1 - Segment ID
#
# Returns FFMPEG WRAP PID from PAUSE file into variable $PAUSE_PID, full path to PAUSE file in $PAUSE_FILEPATH
#
function get_ffmpeg_pause_pid {
    local segment_id=$1
    PAUSE_FILEPATH=$SEMAPHORE_DIR/${segment_id}.pause
    PAUSE_PID=
    if [ -f $PAUSE_FILEPATH ]; then
        log_trace "#READ PID# head -1 $PAUSE_FILEPATH"
        if trace_is_on; then head -1 $PAUSE_FILEPATH >> $CLEANUP_LOG 2>&1; echo "#" >> $CLEANUP_LOG; fi;
        PAUSE_PID=$(head -1 $PAUSE_FILEPATH)
log_trace "PAUSE PID: $PAUSE_PID"
    fi
}

#
# $1 - Segment ID
#
# Returns FFMPEG last position from which the TS files are created (FFMPEG argument -START_NUMBER)
# Position is set in variable $FFMPEG_POS, time of the last position change in $FFMPEG_POS_TIME
# Full filepath to POS file in $POS_FILEPATH
#
function get_ffmpeg_pos {
    local segment_id=$1
    POS_FILEPATH=$SEMAPHORE_DIR/${segment_id}.pos
    if [ -f $POS_FILEPATH ]; then
        log_trace "#READ POS# head -1 $POS_FILEPATH"
        if trace_is_on; then head -1 $POS_FILEPATH >> $CLEANUP_LOG 2>&1; echo "#" >> $CLEANUP_LOG; fi;
        FFMPEG_POS="$(head -1 $POS_FILEPATH)" # Sample value: 123 05-03-2023 12:20:17.655142648, where 123 is the position number
        FFMPEG_POS_TIME="${FFMPEG_POS#* }"    # extract the part after the first space
        FFMPEG_POS=${FFMPEG_POS%% *}          # extract the part before the first space
log_trace "FFMPEG POS: $FFMPEG_POS"
    else
        FFMPEG_POS=
        FFMPEG_POS_TIME=
    fi
}

#
# $1 - Segment ID
# $2 - Signal (for "kill" command)
#
# Send signal to FFMPEG WRAP child processes of the specified Segment ID
# Process ID for FFMPEG WRAP will be retrieved from PID file
#
# Global variable FFMPEG_WRAP_PID will be set to the WRAP PID
#
function signal_ffmpeg {
    local segment_id=$1
    get_ffmpeg_pid $segment_id # get $FFMPEG_WRAP_PID
    log_info "Signaling [$2] to child processes of FFMPEG WRAP with PID=$FFMPEG_WRAP_PID:"
    #
    # FNR>1 will list all subsequent child processes, except the first (main) process
    #
    log_trace "#LIST CHILD PROCESSES# ps -o pid= -p $FFMPEG_WRAP_PID --ppid $FFMPEG_WRAP_PID --forest | awk 'FNR>1{print \$1}'"
    if trace_is_on; then ps -o pid= -p $FFMPEG_WRAP_PID --ppid $FFMPEG_WRAP_PID --forest | awk 'FNR>1{print $1}' >> $CLEANUP_LOG 2>&1; echo "#" >> $CLEANUP_LOG; fi;
    for PID in $(ps -o pid= -p $FFMPEG_WRAP_PID --ppid $FFMPEG_WRAP_PID --forest | awk 'FNR>1{print$1}'); do
        log_info "   Signaling FFMPEG child process PID=$PID [$2]"
        kill $2 $PID
        if [[ "$2" == "-SIGKILL" || "$2" == "-9" ]]; then
            #
            # When killing sleeping process, it will remain sleeping (in status=T). When FFMPEG is using video card which
            # has limited the number of allowed processes then such sleeping process will be counted as active. And card
            # may report Out of memory error when number of active process reaches the limit (even though the processes were killed).
            #
            log_info "   Signaling FFMPEG child process PID=$PID [-SIGCONT] to properly kill the process in case if it is sleeping (status=T)"
            kill -SIGCONT $PID 2>/dev/null
        fi
    done
}

#
# $1 - Segment ID
#
function is_ffmpeg_paused {
    local segment_id=$1
    get_ffmpeg_pid $segment_id # get $FFMPEG_WRAP_PID
    log_debug "Verifying if FFMPEG for Segment ID=$segment_id is paused."
    #
    # FNR>1 will list all subsequent child processes, except the first (main) process
    #
    log_trace "#LIST CHILD PROCESSES# ps -o state= -p $FFMPEG_WRAP_PID --ppid $FFMPEG_WRAP_PID --forest | awk 'FNR>1{print\$1}'"
    if trace_is_on; then ps -o state= -p $FFMPEG_WRAP_PID --ppid $FFMPEG_WRAP_PID --forest | awk 'FNR>1{print $1}' >> $CLEANUP_LOG 2>&1; echo "#" >> $CLEANUP_LOG; fi;
    for STATE in $(ps -o state= -p $FFMPEG_WRAP_PID --ppid $FFMPEG_WRAP_PID --forest | awk 'FNR>1{print$1}'); do
        if [ "$STATE" == "T" ]; then
            log_info "FFMPEG is paused (one of FFMPEG PID=$FFMPEG_WRAP_PID child processes is paused)"
            return
        fi
    done
    log_info "FFMPEG is not paused"
    [ 1 == 0 ] # return false answer
}

#
# $1 - Segment ID
#
# All FFMPEG WRAP child processes will be killed for the specified Segment ID
# process ID for FFMPEG WRAP will be retrieved from PID file
#
# NOTE: It takes ~25 seconds after FFMPEG child process restart till the first TS file
#       is created with the new FFMPEG process
#
function restart_ffmpeg {
    cancel_ffmpeg_resume_if_scheduled $1
    log_info "Restarting FFMPEG child processes for Segment ID=$1"
    signal_ffmpeg $1 -SIGKILL
    #
    # If there is PAUSE file then delete it
    #
    get_ffmpeg_pause_pid $segment_id # get $PAUSE_PID and $PAUSE_FILEPATH
    if [ "$PAUSE_PID" != "" ]; then
        log_debug "Deleting PAUSE file due to restart of FFMPEG"
        rm -f $PAUSE_FILEPATH
    fi
}

#
# $1 - Segment ID
#
# All FFMPEG WRAP child processes will be killed for the specified Segment ID
# Process ID for FFMPEG WRAP will be retrieved from PID file
#
# NOTE: It takes ~25 seconds after FFMPEG child process restart till the first TS file
#       is created with the new FFMPEG process
#
# Return: 0 - failure, 1 - success, 2 - already paused
#
function pause_ffmpeg {
    FFMPEG_WRAP_PID=
    local segment_id=$1
    local result=0
    get_ffmpeg_pid $segment_id # get $FFMPEG_WRAP_PID
    #
    # Create PAUSE file
    #
    if [ "$FFMPEG_WRAP_PID" == "" ]; then
        log_warn "Cannot pause FFMPEG because cannot read PID file for the Segment ID=$1"
    else
        get_ffmpeg_pause_pid $segment_id # get $PAUSE_PID and $PAUSE_FILEPATH
        #
        # Pause FFMPEG WRAP process PID if not already paused
        #
        if [[ "$PAUSE_PID" != "" ]] && [[ "$PAUSE_PID" == "$FFMPEG_WRAP_PID" ]]; then
            log_info "   FFMPEG WRAP process PID child processes are already paused: $FFMPEG_WRAP_PID"
            result=2
        else
            log_info "   Pausing FFMPEG child processes for Segment ID=$1"
            signal_ffmpeg $1 -SIGSTOP
            echo $FFMPEG_WRAP_PID > $PAUSE_FILEPATH
            result=1
        fi
    fi
    return $result
}

#
# $1 - Segment ID
#
# All FFMPEG WRAP child processes will be resumed for the specified Segment ID
# Process ID for FFMPEG WRAP will be retrieved from PID file and PAUSE file
#
# NOTE: It takes ~25 seconds after FFMPEG child process restart till the first TS file
#       is created with the new FFMPEG process
#
function resume_ffmpeg {
    log_info "Resuming FFMPEG child processes for Segment ID=$1"
    FFMPEG_WRAP_PID= # need to determine the value before "signal_ffmpeg" function
    local segment_id=$1
    get_ffmpeg_pid $segment_id # get $FFMPEG_WRAP_PID
    #
    # Read PID from PAUSE file
    #
    get_ffmpeg_pause_pid $segment_id # get $PAUSE_PID and $PAUSE_FILEPATH
    #
    # Resume the process
    #
    if [ "$FFMPEG_WRAP_PID" != "" ]; then
        #
        # Resume FFMPEG WRAP process if the current process PID is the same as for earlier paused process
        #
        if [[ "$PAUSE_PID" != "" ]] && [[ "$PAUSE_PID" == "$FFMPEG_WRAP_PID" ]]; then
            log_info "Resuming FFMPEG child processes for Segment ID=$1"
            signal_ffmpeg $1 -SIGCONT
        else
            log_info "Cannot resume FFMPEG WRAP process with PID=$FFMPEG_WRAP_PID becausee it is not the same as PID from PAUSE file: $PAUSE_PID"
            log_warn "Deleting PAUSE file $PAUSE_FILEPATH because FFMPEG WRAP PID=$FFMPEG_WRAP_PID differs from PID=$PAUSE_PID stored in the PAUSE file"
        fi
        rm -f $PAUSE_FILEPATH
        cancel_ffmpeg_resume $1 # mark that scheduled resume was completed
    fi
}

#
# $1 - Segment ID
# $2 - TS ID
#
# Store TS ID provided in argument $2.
# Only most earlier TS ID will be stored when calling function multiple times
#
function schedule_ffmpeg_restart_for_ts_id {
    local value=${SCHEDULE_RESTART_FFMPEG_FOR_TS_ID[$1]}
    if [ "$value" == "" ]; then
        SCHEDULE_RESTART_FFMPEG_FOR_TS_ID[$1]=$2
        log_info "Scheduled restart of FFMPEG process for TS ID: $2"
    else
        if [ $2 -lt $value ]; then # store earliest TS ID
            SCHEDULE_RESTART_FFMPEG_FOR_TS_ID[$1]=$2
            log_info "Scheduled restart of FFMPEG process for TS ID: $2"
        fi
    fi
}

#
# $1 - Segment ID
# $2 - TS ID (currently played and last accessed by the player)
#
# Function will verify TS ID provided in argument $2 and compare
# with TS ID that is stored for scheduled killing of FFMPEG process
#
# If there are less than 3 segments till the scheduled TS ID then
# all FFMPEG child processes are killed, example:
#    Scheduled: 575 (earlier deleted, so need to kill FFMPEG to re-create it)
#     Argument: 573 (currently accessed by player)
#       Result: FFMPEG is going to be killed (because 2 segments 573,574 are remaining till gap)
#
# NOTE: It takes ~25 seconds after FFMPEG child process restart till the first TS file
#       is created with the new FFMPEG process
#
function restart_ffmpeg_if_scheduled {
    local value=${SCHEDULE_RESTART_FFMPEG_FOR_TS_ID[$1]}
    if [ "$value" != "" ]; then
        log_trace "Scheduled restart of FFMPEG will happen when LA TS ID will be $(($value - $SCHEDULE_RESTART_FFMPEG_TS_ID_COUNT)), current TS ID=$2, deleted TS ID=$value"
        if [ $(($2 + $SCHEDULE_RESTART_FFMPEG_TS_ID_COUNT + 1)) -gt $value ]; then # matching sequence + 1
             log_info "Scheduled restart of FFMPEG activated. Reason: LA TS ID=$2 is approaching deleted TS ID=$value"
             restart_ffmpeg $1
             SCHEDULE_RESTART_FFMPEG_FOR_TS_ID[$1]="" # mark that restart was completed
#             log_info "   Waiting 3 seconds till FFMPEG is restarted and new files created"
#             sleep 3
        fi
    fi
}

#
# $1 - Segment ID
#
function cancel_ffmpeg_restart {
    SCHEDULE_RESTART_FFMPEG_FOR_TS_ID[$1]=""
}

#
# $1 - Segment ID
#
function is_ffmpeg_restart_scheduled {
    [ "${SCHEDULE_RESTART_FFMPEG_FOR_TS_ID[$1]}" != "" ]
    return
}

function cancel_ffmpeg_restart_if_scheduled {
    if is_ffmpeg_restart_scheduled $1; then
        log_info "   Cancelling FFMPEG restart"
        cancel_ffmpeg_restart $1
    fi
}

#
# $1 - Segment ID
# $2 - TS ID
#
# Store TS ID provided in argument $2.
# Only most earlier TS ID will be stored when calling function multiple times
#
function schedule_ffmpeg_resume_for_ts_id {
    local value=${SCHEDULE_RESUME_FFMPEG_FOR_TS_ID[$1]}
    if [ "$value" == "" ]; then
        SCHEDULE_RESUME_FFMPEG_FOR_TS_ID[$1]=$2
        log_info "Scheduled resume of FFMPEG process for TS ID: $2"
    else
        if [ $2 -lt $value ]; then # store earliest TS ID
            SCHEDULE_RESUME_FFMPEG_FOR_TS_ID[$1]=$2
            log_info "Scheduled resume of FFMPEG process for TS ID: $2"
        fi
    fi
}

#
# $1 - Segment ID
# $2 - TS ID (currently played and last accessed by the player)
#
# Function will verify TS ID provided in argument $2 and compare
# with TS ID that is stored for scheduled resuming of FFMPEG process
#
# If there are less than 3 segments till the scheduled TS ID then
# all FFMPEG child processes are resumed, example:
#    Scheduled: 575 (earlier paused, so need to resume FFMPEG to continue writing the file)
#     Argument: 573 (currently accessed by player)
#       Result: FFMPEG is going to be resumed (because 2 segments 573, 574 are remaining till potentially unfinished TS file 575)
#
# NOTE: Resume takes immediate effect on FFMPEG processes
#
function resume_ffmpeg_if_scheduled {
    local value=${SCHEDULE_RESUME_FFMPEG_FOR_TS_ID[$1]}
    if [ "$value" != "" ]; then
        log_trace "Scheduled resume of FFMPEG will happen when LA TS ID will be $(($value - $SCHEDULE_RESUME_FFMPEG_TS_ID_COUNT)), current TS ID=$2, paused TS ID=$value"
        if [ $(($2 + $SCHEDULE_RESUME_FFMPEG_TS_ID_COUNT + 1)) -gt $value ]; then # matching sequence + 1
             log_info "Scheduled resume of FFMPEG is requested. Reason: LA TS ID=$2 is approaching paused TS ID=$value"
             [ 1 == 1 ] # return true answer
             return
        fi
    fi
    [ 1 == 0 ] # return false answer
}

#
# $1 - Segment ID
#
# Resume FFMPEG when buffering will be approaching TS files that were
# modified within last second of Last Modified date/time
#
function schedule_ffmpeg_resume_for_last_modified {
    local segment_id=$1
    local ts_pattern=${segment_id}*.ts
    local line3
    local store_ts_id=$TS_ID # store original $TS_ID
    #
    # Resume FFMPEG for TS files which were modified within the last second
    #
    log_info "Schedule FFMPEG resume for TS files (with non-zero size) which were modified within the last second of latest DATE MODIFIED."
    log_trace "#LIST MODIFIED FILES DESCENDING# find $TRANSCODES_DIR -name \"$ts_pattern\" -type f ! -size 0 -exec stat -c '%.Y %n' {} \; 2>/dev/null | sort -n -r"
    if trace_is_on; then find $TRANSCODES_DIR -name "$ts_pattern" -type f ! -size 0 -exec stat -c '%.Y %n' {} \; 2>/dev/null | sort -n -r >> $CLEANUP_LOG 2>&1; echo "#" >> $CLEANUP_LOG; fi
    RESUME_FROM_MOD_MILLIS=
    for line3 in $(find $TRANSCODES_DIR -name "$ts_pattern" -type f ! -size 0 -exec stat -c '%.Y %n' {} \; 2>/dev/null | sort -n -r); do
        decompose_file_Yn $line3
        RESUME_MOD_MILLIS=$MOD_MILLIS # %Y
        RESUME_FILENAME=$FILENAME     # %n
        #
        # Determine the date/time range of TS files for resuming FFMPEG
        #
        if [ "$RESUME_FROM_MOD_MILLIS" == "" ]; then
            #
            # Store modification date/time of the last modified TS file -1 second in $RESUME_FROM_MOD_MILLIS
            #
            millis_add_seconds $RESUME_MOD_MILLIS -1 # deduct 1 second
            RESUME_FROM_MOD_MILLIS=$MILLIS
            if info_is_on; then
                log_info "Schedule resume for the smallest TS ID from all TS files in range between $(millis_to_date $RESUME_FROM_MOD_MILLIS) and $(millis_to_date $RESUME_MOD_MILLIS)."
            fi
        fi
        if [ "$RESUME_MOD_MILLIS" \> "$RESUME_FROM_MOD_MILLIS" ]; then # stop deleting TS files when their modification date is within the last one second range
            #
            # Schedule resuming FFMPEG process before the next TS ID
            #
            extract_ts_id $SEGMENT_ID "$RESUME_FILENAME" # into $TS_ID
            schedule_ffmpeg_resume_for_ts_id $SEGMENT_ID $(($TS_ID + 1)) # only for the smallest TS ID in this loop will be scheduled
                                                                         # TS_ID + 1 is used because resuming will happen before reaching TS_ID + 1
        else
            if ([ "$RESUME_MOD_MILLIS" \< "$RESUME_FROM_MOD_MILLIS" ] || [ "$RESUME_MOD_MILLIS" == "$RESUME_FROM_MOD_MILLIS" ]); then
                break # do not continue looping through files because the list is sorted by modification date in descending order
            fi
        fi
    done
    TS_ID=$store_ts_id # revert back the original TS_ID as it may be globally used by the calling function
}

#
# $1 - Segment ID
#
function cancel_ffmpeg_resume {
    SCHEDULE_RESUME_FFMPEG_FOR_TS_ID[$1]=""
}

#
# $1 - Segment ID
#
function is_ffmpeg_resume_scheduled {
    [ "${SCHEDULE_RESUME_FFMPEG_FOR_TS_ID[$1]}" != "" ]
    return
}

function cancel_ffmpeg_resume_if_scheduled {
    if is_ffmpeg_resume_scheduled $1; then
        log_info "   Cancelling FFMPEG resume"
        cancel_ffmpeg_resume $1
    fi
}

#
# $1 - Segment ID
#
# Store time when buffering started for the last accessed TS file
#
function store_ts_buffer_seconds {
    SEGMENT_LA_BUFF_TIME_ARRAY["$1"]=$SECONDS
}

#
# $1 - Segment ID
#
# Return seconds lapsed since buffering started for the last accessed TS file
#
function get_ts_buffer_seconds {
    echo $(( $SECONDS-SEGMENT_LA_BUFF_TIME_ARRAY["$1"] ))
}

#
# $1 - Segment ID
#
# Set time for inactive time monitoring when LA not found
#
function store_ts_inactive_seconds {
    SEGMENT_INACTIVE_TIME_ARRAY["$1"]=$SECONDS
}

#
# $1 - Segment ID
#
# Remove inactive time monitoring
#
function clear_ts_inactive_seconds {
    SEGMENT_INACTIVE_TIME_ARRAY["$1"]=""
}

#
# $1 - Segment ID
#
# Return TS ID of the TS file that was last accessed (buffered)
#
function get_last_accessed_ts_id {
    echo ${SEGMENT_LA_TS_ID_ARRAY["$1"]}
}

#
# $1 - Segment ID
# $1 - TS ID
#
# Set TS ID of the last accessed (buffered) TS file
#
function store_last_accessed_ts_id {
    SEGMENT_LA_TS_ID_ARRAY["$1"]=$2
}

#
# $1 - Segment ID
#
# Retrieve time for inactive time monitoring when LA not found
#
function get_ts_inactive_seconds {
    echo $(( $SECONDS-SEGMENT_INACTIVE_TIME_ARRAY["$1"] ))
}

#
# $1 - Segment ID
#
# True if inactive time monitoring is used when LA not found
#
function tracking_ts_inactive_seconds {
    [ "${SEGMENT_INACTIVE_TIME_ARRAY[$1]}" != "" ]
    return
}

#
# $1 - Key
# $2 - Array
#
# Return element from array $2 by using key in $1
# Returns empty string if not found
#
#unction get_element_by_key {
#   if exists "$1" in $2; then
#       eval 'echo ${'$2'[$1]}'
#   else
#       echo ""
#   fi
#

#
# $1 - Segment ID
#
# Return last recorded buffering time
# Returns -1 if no record exists, or if Segment ID not found
#
function get_ts_buffer_time_stats_last {
    if exists "$1" in SEGMENT_LA_BUFF_TIME_STAT; then
        local values=($(echo ${SEGMENT_LA_BUFF_TIME_STAT["$1"]} | tr ' ' "\n"))
        local count=${#values[@]}
        if [ $count -eq 0 ]; then
            echo -1
        else
            echo ${values[(($count - 1))]}
        fi
    else
        echo -1
    fi
}

#
# $1 - Segment ID
#
# Return last recorded buffering size
# Returns -1 if no record exists, or if Segment ID not found
#
function get_ts_buffer_size_stats_last {
    if exists "$1" in SEGMENT_LA_BUFF_SIZE_STAT; then
        local values=($(echo ${SEGMENT_LA_BUFF_SIZE_STAT["$1"]} | tr ' ' "\n"))
        local count=${#values[@]}
        if [ $count -eq 0 ]; then
            echo -1
        else
            echo ${values[(($count - 1))]}
        fi
    else
        echo -1
    fi
}

#
# $1 - first number
# $2 - second number
# $3 (optional) - if specified (eg, "true") then will return always positive percentage
#
# Calculate difference between numbers in percentage
#
# Source: https://stackoverflow.com/a/24253318
function diff_perc {
    local divider=$2
    local positive=$3
    [ "$divider" -ne 0 ] || divider=1 # set divider to 1 if divider is 0
    local diff=$(($divider - $1))
    [ "$positive" == "" ] || [ "$diff" -ge 0 ] || diff=$((-diff)) # ensure it is always a positive number when $3 is specified
    echo $((diff * 100 / $divider))
}

#
# $1 - first number
# $2 - second number
#
# Returns argument which is largest number
#
function max {
    if [ "$1" -gt "$2" ]; then
        echo $1
    else
        echo $2
    fi
}

#
# $1 - Segment ID
# $2 - Seconds measured for the buffering between two subsequent TS files
# $3 - Buffered TS file size in bytes
#
# Add new measurement to the last x measurements of how much time it takes for
# client player to buffer between two subsequent TS files. Store the file size.
#
# Number of measurements is determined by $SEGMENT_LA_BUFF_STAT_SIZE
#
# NOTE: when playback quality is changed (for example, 4K to 1080p) then
#       collected stats will still be re-usable because calculated
#       network transfer speed bytes per second per Segment ID will not change.
#
# NOTE: call this function only when sure that file was buffered fully -
#       if player position has changed, then file buffering may be interrupted
#       halfway and such measurement will not represent a valid transfer speed.
#
function update_ts_buffer_stats {
    log_debug "STATS: Updating TS file buffering statistics for SEGMENT ID: $1"
    local time_values
    local size_values
    if exists "$1" in SEGMENT_LA_BUFF_TIME_STAT; then
        time_values=($(echo ${SEGMENT_LA_BUFF_TIME_STAT["$1"]} | tr ' ' "\n"))
        size_values=($(echo ${SEGMENT_LA_BUFF_SIZE_STAT["$1"]} | tr ' ' "\n"))
        local count=${#time_values[@]} # count of element in time_values and size_values is the same
        log_trace "STATS: stored count: $count, max: $SEGMENT_LA_BUFF_STAT_SIZE"
        if [ $count -eq $SEGMENT_LA_BUFF_STAT_SIZE ]; then
            log_trace "STATS: Number of stored records reached $SEGMENT_LA_BUFF_STAT_SIZE. Removing the first record."
            time_values=( "${time_values[@]:1}" ) # remove the first element from array
            size_values=( "${size_values[@]:1}" )
        fi
    else
        log_debug "STATS: Initializing TS file buffering statistics"
        time_values=() # define empty array
        size_values=()
    fi
    #
    # Check if new size in argument $3 and the last stored size differs from average size calculated before
    # by X% or more. If so then remove all but the two values - 1) last stored recording and 2) the new size.
    #
    local avg_size_before=$(get_ts_buffer_avg_size "$1" 1) # average size, except the last recording
    if [ $avg_size_before -ne 0 ]; then
        if [ $avg_size_before -gt $3 ]; then # max number is always 100%, used as divider
            local max=$avg_size_before
            local min=$3
        else
            local max=$3
            local min=$avg_size_before
        fi
        local perc=$(diff_perc $min $max "true")
        if [ $perc -ge $SEGMENT_LA_BUFF_SIZE_STAT_RESET_PERC ]; then # compare average size (excluding last registered size) with current size value
            log_trace "STATS: Buffering size $3 bytes per TS file differs from average statistics by ${perc}%, exceeding the size treshhold ${SEGMENT_LA_BUFF_SIZE_STAT_RESET_PERC}%"
            local size_last=$(get_ts_buffer_size_stats_last "$1") # get last recorded size
            if [ $size_last -ne -1 ]; then                    # if found
                local perc=$(diff_perc $avg_size_before $size_last "true")
                if [ $perc -ge $SEGMENT_LA_BUFF_SIZE_STAT_RESET_PERC ]; then # compare average size (excluding last registered size) with last registered size
                    log_trace "STATS: Previous buffering size $size_last bytes per TS file differs from average statistics by ${perc}%"
                    local size_time=$(get_ts_buffer_time_stats_last "$1") # get last recorded time
                    log_debug "    => Re-setting buffering statistics (>${SEGMENT_LA_BUFF_SIZE_STAT_RESET_PERC}%), keeping the last buffering time ($size_time seconds) and size ($size_last bytes)"
                    time_values=($size_time) # re-define array using only the last recording
                    size_values=($size_last)
                fi
            fi
        fi
    fi
    log_debug "STATS: Registering buffering time of $2 seconds for TS file with $3 bytes in size"
    time_values+=($2) # add new element to the end of array
    size_values+=($3)
    #
    # Store in the array for Segment ID
    #
    SEGMENT_LA_BUFF_TIME_STAT["$1"]=${time_values[@]}
    SEGMENT_LA_BUFF_SIZE_STAT["$1"]=${size_values[@]}
}

#
# $1 - Segment ID
# $3 - TS file size in bytes
#
# Add new measurement to the last x measurements of how big is TS file size
#
# Number of measurements is determined by $SEGMENT_TS_SIZE_STAT_SIZE - not used
#
function update_ts_size_stats {
    log_debug "STATS: Updating TS file size statistics for SEGMENT ID: $1"
    local size_values
    if exists "$1" in SEGMENT_TS_SIZE_STAT; then
        size_values=($(echo ${SEGMENT_TS_SIZE_STAT["$1"]} | tr ' ' "\n"))
#        local count=${#time_values[@]} # count of element in time_values and size_values is the same
#        log_trace "STATS: stored count: $count, max: $SEGMENT_TS_SIZE_STAT_SIZE"
#        if [ $count -eq $SEGMENT_TS_SIZE_STAT_SIZE ]; then
#            log_trace "STATS: Number of stored records reached $SEGMENT_TS_SIZE_STAT_SIZE. Removing the first record."
#            size_values=( "${size_values[@]:1}" ) # remove the first element from array
#        fi
    else
        log_debug "STATS: Initializing TS file size statistics"
        size_values=() # define empty array
    fi
    # #
    # # Check if new size in argument $2 and the last stored size differs from average size calculated before
    # # by X% or more. If so then remove all but the two values - 1) last stored recording and 2) the new size.
    # #
    # local avg_size_before=$(get_ts_avg_size "$1" 1) # average size, except the last recording
    # if [ $avg_size_before -ne 0 ]; then
        # if [ $avg_size_before -gt $2 ]; then # max number is always 100%, used as divider
            # local max=$avg_size_before
            # local min=$2
        # else
            # local max=$2
            # local min=$avg_size_before
        # fi
        # local perc=$(diff_perc $min $max "true")
        # if [ $perc -ge $SEGMENT_TS_SIZE_STAT_RESET_PERC ]; then # compare average size (excluding last registered size) with current size value
            # log_trace "STATS: Size $2 bytes per TS file differs from average statistics by ${perc}%, exceeding the size treshhold ${SEGMENT_TS_SIZE_STAT_RESET_PERC}%"
            # local size_last=$(get_ts_size_stats_last "$1") # get last recorded size
            # if [ $size_last -ne -1 ]; then                    # if found
                # local perc=$(diff_perc $avg_size_before $size_last "true")
                # if [ $perc -ge $SEGMENT_TS_SIZE_STAT_RESET_PERC ]; then # compare average size (excluding last registered size) with last registered size
                    # log_trace "STATS: Previous TS file size $size_last bytes per TS file differs from average statistics by ${perc}%"
                    # local size_time=$(get_ts_buffer_time_stats_last "$1") # get last recorded time
                    # log_debug "    => Re-setting TS file size statistics (>${SEGMENT_TS_SIZE_STAT_RESET_PERC}%), keeping the last TS file size ($size_last bytes)"
                    # size_values=($size_last) # re-define array using only the last recording
                # fi
            # fi
        # fi
    # fi
    log_debug "STATS: Registering TS file size of $2 bytes"
    size_values+=($2) # add new element to the end of array
    #
    # Store in the array for Segment ID
    #
    SEGMENT_TS_SIZE_STAT["$1"]="${size_values[@]}"
}

function reset_ts_size_stats {
    SEGMENT_TS_SIZE_STAT["$1"]=""
}

# Divide and round up to nearest whole number
# If divider is 0 then return 0 (not error)
#
# Source: https://stackoverflow.com/a/24253318
function div_roundup {
    if [ $2 -eq 0 ]; then
        echo 0
    else
        echo $(( ($1 + $2/2)/$2 ))
    fi
}

#
# $1 - Segment ID
# $2 (optional) - exclude last "n" size records from calculation
#
# Function returns average size of segment TS file buffering
#
function get_ts_buffer_avg_size {

    if exists "$1" in SEGMENT_LA_BUFF_SIZE_STAT; then
        local bytes
        local sum=0
        local iteration=0
        local values=($(echo ${SEGMENT_LA_BUFF_SIZE_STAT["$1"]} | tr ' ' "\n"))
        local exclude=0; [[ "$2" == "" ]] || exclude=$2
        local count=${#values[@]}
        for bytes in ${values[@]}; do
            [ $(($iteration + $exclude)) -lt $count ] || break; # break when reached items to exclude
            ((sum += $bytes))
            ((iteration ++))
        done
        local divider=$(($count - $exclude))
        div_roundup $sum $divider # divide size_sum / num_of_stat_entries
    else
        echo 0
    fi
}

#
# $1 - Segment ID
# $2 (optional) - exclude last "n" size records from calculation
#
# Function returns average size of segment TS file size
#
function get_ts_avg_size {

    if exists "$1" in SEGMENT_TS_SIZE_STAT; then
        local bytes
        local sum=0
        local iteration=0
        local values=($(echo ${SEGMENT_TS_SIZE_STAT["$1"]} | tr ' ' "\n"))
        local exclude=0; [[ "$2" == "" ]] || exclude=$2
        local count=${#values[@]}
        for bytes in ${values[@]}; do
            [ $(($iteration + $exclude)) -lt $count ] || break; # break when reached items to exclude
            ((sum += $bytes))
            ((iteration ++))
        done
        local divider=$(($count - $exclude))
        div_roundup $sum $divider # divide size_sum / num_of_stat_entries
    else
        echo 0
    fi
}

#
# $1 - array of actual Segment IDs
#
# Example: array=("segment1")
#          remove_unused_segments array
#
# Clean-up arrays that store runtime data based on Segment ID
# All arrays must be included in array $MAINTAINED_ARRAYS
#
function remove_unused_segments {
    local key
    #local segments=("$@")
    local segments
    eval 'segments=${'$1'[@]}'
    log_trace "Removing unused Segment IDs from runtime arrays:";
    #
    # Create temporary arrays with required elements
    #
    for name in ${MAINTAINED_ARRAYS[@]}; do
        log_trace "   Array: $name"
        unset array
        declare -A array; # declare makes variable local by default
        for key in $(eval 'echo ${!'$name'[@]}'); do
            if value "$key" in segments; then
               array["$key"]=$(eval 'echo ${'$name'["'$key'"]}'); # ${SEGMENT_LA_BUFF_TIME_STAT["$key"]};
               log_trace "      Keeping Segment ID: $key"
            else
               log_trace "      Removing Segment ID: $key"
            fi
        done
        #
        # Re-define and initialize arrays with required elements
        #
        eval 'unset '$name
        eval 'declare -Ag '$name; # declare global variable
        for key in ${!array[@]}; do eval $name'["'$key'"]=${array["'$key'"]}'; done
    done;
}


#
# Test whether the key or index is present in an array
#
# Example:
#          if exists "key" in array; then echo exists; fi
#
# Source: https://stackoverflow.com/a/13221491
#
function exists {
    if [ "$2" != in ]; then
        echo "Incorrect usage."
        echo "Correct usage: exists {key} in {array}"
        return
    fi   
    eval '[ ${'$3'[$1]+a} ]'
}

#
# $1 PID
#
# Test if process is appearing as active process in system process table. PID_ACTIVE variable = 1 if active, 0 if not active
#
function test_pid_active {
    PID_ACTIVE=1
    local pid_comm=$(ps -o comm= -p $1) # command line from the old PID in process table
    if [ "$pid_comm" == "" ]; then
        # process is not existing in process table, so it is not running
        PID_ACTIVE=0
    else
        # test if this is zombie process
        [[ "$pid_comm" =~ ^.+(\<defunct\>)$ ]]
        if [ "${BASH_REMATCH[1]}" == "<defunct>" ]; then
            PID_ACTIVE=0
        fi
    fi
}

# Get total size of transcodes directory
DIR_SIZE=$(df $TRANSCODES_DIR -B1 --output=size | sed '1d')
log_info "Total $TRANSCODES_DIR directory size is $DIR_SIZE bytes"
log_trace "----------------------------------------------------------"
log_trace "CALCULATE INITIAL SPACE"
        #TS_SPACE_RESERVED=$(div_roundup $(( DIR_SIZE*95/100 )) $TS_SPACE_RESERVED_MIN_DIVIDER ) # divide 95% of total directory size with number of PIDs + 1 reserved, minimum number is set by $TS_SPACE_RESERVED_MIN_DIVIDER)
        TS_SPACE_RESERVED=$(( $(( DIR_SIZE*95/100 )) / $TS_SPACE_RESERVED_MIN_DIVIDER )) # divide 95% of total directory size with number of PIDs + 1 reserved, minimum number is set by $TS_SPACE_RESERVED_MIN_DIVIDER)
        TS_SPACE_RESERVED_PERC=$(div_roundup $(( TS_SPACE_RESERVED*100 )) $DIR_SIZE)
        REMAINING_DIR_SIZE=$(( DIR_SIZE*95/100 - TS_SPACE_RESERVED ))           # 95% directory size without reserved space
        REMAINING_DIR_SIZE_PERC=$(( 95 - TS_SPACE_RESERVED_PERC ))

# check if PID file exists (clean up process may be already running)
if [ -f $CLEANUP_PID ]; then

   OLD_PID=$(head -1 $CLEANUP_PID 2>/dev/null)
   log_info "Previous PID file found with PID=$OLD_PID"

   # check if PID belongs to clean up process (or it might be terminated and another process working with the same PID)

   OLD_CMD=$(cat /proc/$OLD_PID/cmdline 2>&1 | tr '\0' ' ')

   if [[ "$OLD_CMD" == "/bin/bash $SCRIPT_DIR/transcode.cleanup.sh"* ]] \
   || [[ "$OLD_CMD" == "bash $SCRIPT_DIR/transcode.cleanup.sh"* ]]; then

        test_pid_active $OLD_PID
        OLD_PID_ACTIVE=$PID_ACTIVE

        if [ -f $CLEANUP_SHUTDOWN ]; then
            SHUTDOWN_PID=$(head -1 $CLEANUP_SHUTDOWN 2>/dev/null)
            if ! get_file_mod_date $CLEANUP_SHUTDOWN; then
                log_warn "Could not retrieve modification date/time from the shutdown flag file, it seems that there is another clean up process that deleted it"
                exit
            fi
            CLEANUP_SHUTDOWN_MOD_TIME="$MOD_DATE $MOD_TIME"
            if [ $OLD_PID -eq $SHUTDOWN_PID ]; then
                log_info "Clean up process with PID=$OLD_PID is currently doing shutdown, will try to cancel the shutdown by deleting the shutdown flag file"
                SHUTDOWN_PID_ACTIVE=$OLD_PID_ACTIVE
            else
                log_info "Found shutdown flag file from a different clean up process with PID=$SHUTDOWN_PID than the one which is currently running with PID=$OLD_PID. Will try to delete the shutdown flag file"
                test_pid_active $SHUTDOWN_PID
                SHUTDOWN_PID_ACTIVE=$PID_ACTIVE
            fi
            rm -f $CLEANUP_SHUTDOWN
            if [ $SHUTDOWN_PID_ACTIVE -eq 1 ]; then
                COUNTER=$SECONDS
                while [ -f $CLEANUP_PID ]; do
                    if ! get_file_mod_date $CLEANUP_PID; then
                        if [ -f $CLEANUP_PID ]; then
                            log_warn "Could not retrieve modification date/time of the cleanup process PID file $CLEANUP_PID, although the file exists. Exiting."
                            exit 1
                        else
                            log_info "Could not retrieve modification date/time of the cleanup process PID file $CLEANUP_PID, because it was deleted"
                            break;
                        fi
                    fi
                    CLEANUP_PID_MOD_TIME="$MOD_DATE $MOD_TIME"
                    if [ "$CLEANUP_PID_MOD_TIME" \> "$CLEANUP_SHUTDOWN_MOD_TIME" ]; then
                        log_info "Clean up process with PID=$SHUTDOWN_PID signaled that it is active and will continue to work. Exiting"
                        exit
                    fi
                    if [ $(($SECONDS-COUNTER)) -gt 5 ]; then # wait for 5 seconds
                        log_info "There was no response from the clean up script with PID=$SHUTDOWN_PID during last 5 seconds, deleting it's PID file and will be working instead"
                        kill -9 $SHUTDOWN_PID
                        rm -f $CLEANUP_PID
                        break
                    fi
                    sleep 0.2
                done
            else
                log_info "Clean up process PID=$SHUTDOWN_PID which was using shutdown flag file is not currently running"
            fi
        fi
        if ([ -f $CLEANUP_PID ] && [ $OLD_PID_ACTIVE -eq 1 ]); then
            log_info "PID $OLD_PID belongs to an active clean up process, exiting the current process and leaving $OLD_PID running"
            exit
        else
            log_info "PID $OLD_PID is no longer running, leaving current process running"
        fi
    else
        log_info "PID $OLD_PID is not clean up process, leaving current process running"
    fi
fi

#
# Capture PID of this bash script in PID file
#
echo $$ > $CLEANUP_PID
#
# PID file will not be created if directory space is 100% full
#
if [ $? != 0 ]; then
    log_warn "Failed to create PID file because space is full for $TRANSCODES_DIR or lack of permissions. Exiting"
    exit
fi
if [ -f $CLEANUP_STOPPED ]; then
    rm -f $CLEANUP_STOPPED # remove flag file which was left from the last script shutdown
fi
if [ -f $CLEANUP_SHUTDOWN ]; then
    rm -f $CLEANUP_SHUTDOWN # remove shutdown flag file which may be left in case if last script crashed (or was killed) during shutdown countdown
fi
#
# Verify that no other parallel clean up process has written to PID file
#
sleep 0.1 # wait for other clean up processes to potentially write to PID file
OLD_PID=$(head -1 $CLEANUP_PID)
if [ "$OLD_PID" != "$$" ]; then
    log_warn "Another clean up process is using PID file $CLEANUP_PID, exitting."
    exit
fi

INITIALIZING=1 # running cleanup script for the first time
LAST_DIR_SPACE_USED_PERC=
DEFAULT_IFS=$IFS
IFS=$'\n'         # this will make FOR parsing each line instead of each whitespace
shopt -s nullglob # expands the glob to empty string when there are no matching files in the directory.
                  # otherwise "du" and other bash commands will not be able to always find files
set +f            # disable filename globbing (making the star to work in command: for s in "abc def"; do test+=$s*; done)

#
# This is main loop with sleep
#
while true; do

    if debug_is_on && [ $CLEANUP_LOG_TIMESTAMP -ne 1 ]; then
        log_debug "TIME NOW: $(date +'$DATE_FORMAT')"
    fi
    if [ -f $CLEANUP_CMD_EXIT ]; then
        log_warn "Encountered stop flag file which signals current process to exit. Exiting"
        rm -f $CLEANUP_CMD_EXIT 2>>$CLEANUP_LOG
        exit
    fi
    #
    # Find if there are any 0-size files, then set NO_SPACE_LEFT flag
    #
    # All 0-size files will be deleted at the end of this loop
    #
    NO_SPACE_LEFT=0 # delete almost all TS files as there is no free space left
    LM_FILES_ARRAY=() # array of "n" last modified files in transcodes directory
    #
    DIR_SPACE_USED=$(du -csb $TRANSCODES_DIR | tail -1 | awk '{print $1}') # total space used by any files in transcodes directory
    DIR_SPACE_USED_PERC=$(($DIR_SPACE_USED*100/$DIR_SIZE))                 # percent of total space used
    if [[ "$LAST_DIR_SPACE_USED_PERC" == "" || \
           $LAST_DIR_SPACE_USED_PERC -ne $DIR_SPACE_USED_PERC || \
           $DIR_SPACE_USED_PERC -ge $CLEANUP_ALL_WHEN_SPACE_REACHES_PERC ]]; then # avoid printing to log if no changes
        log_info ""
        log_trace "Total space used by TS files is ${DIR_SPACE_USED_PERC}% from 100% of total directory size"
    fi
    LAST_DIR_SPACE_USED_PERC=$DIR_SPACE_USED_PERC
    
    if [ $DIR_SPACE_USED_PERC -ge $CLEANUP_ALL_WHEN_SPACE_REACHES_PERC ]; then
        #
        # Do not test for zero-size files, because this script is deleting zero-size files at the end,
        # so here in the next cycle we most likely will not see zero-size file, even thought it existed milliseconds ago
        #
        
        #if test -n "$(find $TRANSCODES_DIR -maxdepth 1 -size 0 -type f -print -quit)"; then
        #    #
        #    # Print trace only if there is anything processed (to avoid cluttering log file with unneeded messages)
        #    #
        #    log_trace "#CHECK 0-SIZE FILES# find $TRANSCODES_DIR -maxdepth 1 -size 0 -type f -print -quit"
        #    if trace_is_on; then find $TRANSCODES_DIR -maxdepth 1 -size 0 -type f -print -quit >> $CLEANUP_LOG 2>&1; echo "#" >> $CLEANUP_LOG; fi
            #
            # Check space used in transcodes directory (for all Segments)
            #
            log_warn "WARNING: Space used ${DIR_SPACE_USED_PERC}% exceeds ${CLEANUP_ALL_WHEN_SPACE_REACHES_PERC}%"
        #    log_warn "        There are zero-size TS files found in transcodes directory $TRANSCODES_DIR"

            NO_SPACE_LEFT=1
        #fi
    fi

    ACTUAL_SEGMENTS_ARRAY=() # reset array of actual Segment IDs (segments with or without TS files)

    #
    # Delete all PID files in /config/transcodes which do not have corresponding TS files.
    # Pause FFMPEG WRAP process (and child processes) when TS files of the process consume more than allowed directory space
    #
    ACTUAL_PIDS=()
    ACTUAL_PID_COUNT=0 # count number of PIDs which have at least one TS file
    for f in $SEMAPHORE_DIR/*.pid; do
       if [ "$f" == "$CLEANUP_PID" ]; then
           continue; # ignore PID file of this cleanup script
       fi
       if [ $CLEANUP_INACTIVITY_SHUTDOWN_COUNTER -ne -1 ]; then # if activated
           log_info "Cancelling cleanup script shutdown because new Segment file was found"
           CLEANUP_INACTIVITY_SHUTDOWN_COUNTER=-1 # deactivate cleanup script shutdown inactivity monitor
           if [ -f $CLEANUP_SHUTDOWN ]; then
              rm -f $CLEANUP_SHUTDOWN # remove shutdown flag file
              echo $$ > $CLEANUP_PID # update timestamp of the PID file to signal other clean up processes that this script is still active
           fi
       fi
       # basepath will contain file path and SEGMENT_ID (SEGMENT_ID) of the PID file, for example: /config/transcodes/141b4b5b5c3123f4414d4f124f41d14d
       basepath=${f%.*}
       SEGMENT_ID=${basepath##*/} # for example, 141b4b5b5c3123f4414d4f124f41d14d
       ACTUAL_SEGMENTS_ARRAY+=("$SEGMENT_ID") # add Segment ID to array
       TS_PATTERN=${SEGMENT_ID}*.ts
       basepath="$TRANSCODES_DIR/$SEGMENT_ID" # re-define $basepath
       LAST_FFMPEG_POS_CHANGE=${SEGMENT_LAST_POS_CHANGE[$SEGMENT_ID]}
       #log_trace "M3U8 LIST ======================================================="
       #if trace_is_on; then cat ${basepath}.m3u8 >> $CLEANUP_LOG 2>&1; echo "==================================================================================================" >> $CLEANUP_LOG; fi
       #log_trace "POS ============================================================="
       #if trace_is_on; then cat $SEMAPHORE_DIR/${SEGMENT_ID}.pos >> $CLEANUP_LOG 2>&1; echo "==================================================================================================" >> $CLEANUP_LOG; fi
       #
       # If there are TS files in transcodes directory for this Segment ID
       #
       if compgen -G "${basepath}*.ts" > /dev/null; then
       
          log_debug "--- Processing TS files for Segment ID: $SEGMENT_ID --------";
          if [ $INITIALIZING -eq 1 ]; then
            #
            # If FFMPEG is paused then we need to resume it at some moment otherwise playback will stop
            # when buffering reaches the last TS file. We assume that last TS files that were created by
            # FFMPEG before pausing may not be fully writen, so we want to resume when buffering
            # reaches TS files before the files that were modified in the last second before pausing.
            #
            if is_ffmpeg_paused $SEGMENT_ID; then
                log_info "FFMPEG for Segment ID=$SEGMENT_ID is paused. Scheduling resume for the TS files that were last modified.";
                schedule_ffmpeg_resume_for_last_modified $SEGMENT_ID # smallest TS ID which was last modified within last second before pause
            fi
          fi
          #
          #
          #
          ACTUAL_PIDS+=($SEGMENT_ID)
          ((ACTUAL_PID_COUNT++))
          LA_FOUND=0
          LA_TS_ID=
          LA_FILENAME=
          LA_FILESIZE=
          LA_ACC_DATE=
          LA_ACC_TIME=
          #
          # Retrieve "last accessed" TS ID for Segment ID to determine if current "last accessed" is
          # different -> indicates playback position change
          #
          LA_FOUND_TS_ID=$(get_last_accessed_ts_id $SEGMENT_ID)
          #
          # Find TS file which was last accessed after it was modified
          # Ignore 0-size files
          #
          # Delete all TS files which were accessed before this last file (but only those that
          # were accessed after modified)
          #
          # List AMF (Last Accessed Date/Time, Last Modified Date/Time and Filename), sort descening (latest is first)
          # Note: When file is created it will have Last Accessed = Last Modified
          #
          log_trace "#LIST ACCESSED FILES DESC# find $TRANSCODES_DIR -name \"$TS_PATTERN\" -type f ! -size 0 -exec stat -c '%x %y %s %n' {} \; 2>/dev/null | sort -n -r"
          if trace_is_on; then find $TRANSCODES_DIR -name "$TS_PATTERN" -type f ! -size 0 -exec stat -c '%x %y %s %n' {} \; 2>/dev/null | sort -n -r >> $CLEANUP_LOG 2>&1; echo "#" >> $CLEANUP_LOG; fi
          for line in $(find $TRANSCODES_DIR -name "$TS_PATTERN" -type f ! -size 0 -exec stat -c '%x %y %s %n' {} \; 2>/dev/null | sort -n -r); do
        
            decompose_file_xysn $line
            if [ "$ACC_DATE $ACC_TIME" \> "$MOD_DATE $MOD_TIME" ]; then
                #
                # Locate the last accessed file
                #
                LA_FOUND=1
                LA_FILENAME=$FILENAME
                LA_FILESIZE=$FILESIZE
                LA_ACC_DATE="$ACC_DATE"
                LA_ACC_TIME="$ACC_TIME"
# LA_BUFF_TIMESTAMP_LAST=${SEGMENT_LA_BUFF_TIMESTAMP_ARRAY[$SEGMENT_ID]} # Last access (buffer) time will be compared with current access time
# LA_BUFF_TIMESTAMP="$ACC_DATE $ACC_TIME"                                # to monitor and determine if playback is stalling (or paused)
# SEGMENT_LA_BUFF_TIMESTAMP_ARRAY[$SEGMENT_ID]=$LA_BUFF_TIMESTAMP
                extract_ts_id $SEGMENT_ID "$FILENAME" # into $TS_ID
                LA_TS_ID=$TS_ID

                log_debug "LAST ACCESSED TS FILE: $LA_FILENAME (accessed at $ACC_DATE $ACC_TIME)"
                break
            fi
          done
          #
          # DELETE LAST MODIFIED TS FILES IF SPACE IS COMPLETELY FULL (zero-size TS files exist)
          #
          # If there is no space left (can be in situation when there are files left from
          # unclean shutdown of Jellyfin, and FFMPEG WRAP is launched for the first time)
          # then delete the non-zero TS file with latest DATE MODIFIED from each
          # Segment ID - it may be corrupted (not fully writen) - sotred descending (latest first)
          #
          if [ $NO_SPACE_LEFT -eq 1 ]; then
              #
              if [ $LA_FOUND -eq 0 ]; then
                  #
                  # If no TS file was yet accessed by the client then restart FFMPEG because
                  # we do not know which file in couple of seconds will be accessed so we cannot
                  # avoid deleting it.
                  #
                  # Delete all Segment ID files and restart FFMPEG immediately
                  #
                  log_info "Deleting all TS files and restarting FFMPEG because no file was accessed (buffered) by the client and there is no space left in transcodes directory."
                  # Do not check for PID change
                  pause_ffmpeg $SEGMENT_ID # pause before deleting TS files to avoid that FFMPEG will continue to produce them
                  rm -f ${basepath}*.ts    # delete TS files before restarting FFMPEG to avoid that restart is quick and new files will be created before rm command finishes
                  restart_ffmpeg $SEGMENT_ID
              else
                  #
                  # Pause FFMPEG
                  # resume will not be scheduled because FFMPEG needs to be restarted when buffering
                  # gets close to the deleted TS files, so resume is not needed
                  #
                  log_info "Pausing FFMPEG because there is no space left in transcodes directory."
                  # Do not check for PID change
                  pause_ffmpeg $SEGMENT_ID
                  #
                  # Delete TS files which were modified within the last second
                  #
                  log_info "Deleting TS files (with non-zero size) which were modified within the last second of latest DATE MODIFIED:"
                  log_trace "#LIST MODIFIED FILES DESCENDING# find $TRANSCODES_DIR -name \"$TS_PATTERN\" -type f ! -size 0 -exec stat -c '%.Y %n' {} \; 2>/dev/null | sort -n -r"
                  if trace_is_on; then find $TRANSCODES_DIR -name "$TS_PATTERN" -type f ! -size 0 -exec stat -c '%.Y %n' {} \; 2>/dev/null | sort -n -r >> $CLEANUP_LOG 2>&1; echo "#" >> $CLEANUP_LOG; fi
                  DEL_FROM_MOD_DATE=
                  for line2 in $(find $TRANSCODES_DIR -name "$TS_PATTERN" -type f ! -size 0 -exec stat -c '%.Y %n' {} \; 2>/dev/null | sort -n -r); do
                      decompose_file_Yn $line2
                      DEL_MOD_MILLIS=$MOD_MILLIS # %Y
                      DEL_FILENAME=$FILENAME     # %n
                      #
                      # Determine the date/time range for deleting last modified TS files
                      #
                      if [ "$DEL_FROM_MOD_DATE" == "" ]; then
                          #
                          # Store modification date/time of the last modified TS file -1 second in $DEL_FROM_MOD_DATE
                          #
                          millis_add_seconds $DEL_MOD_MILLIS -1 # deduct 1 second
                          DEL_FROM_MOD_DATE=$MILLIS
                          log_info "All TS files in range between $(millis_to_date $DEL_FROM_MOD_DATE) and $(millis_to_date $DEL_MOD_MILLIS) will be deleted."
                      fi
                      if [ "$DEL_MOD_MILLIS" \< "$DEL_FROM_MOD_DATE" ]; then # stop deleting TS files when their modification date is less
                          break
                      fi
                      #
                      # If deleting last accessed file then need to restart FFMPEG, because
                      # client will not be able to continue buffering
                      #
                      if [ "$LA_FILENAME" == "$DEL_FILENAME" ]; then
                          log_info "   Deleting not possible for (modified $(millis_to_date $DEL_MOD_MILLIS)): $DEL_FILENAME because this is the last accessed file by client"
                          log_info "   Restarting FFMPEG and deleting all TS files for Segment ID=$SEGMENT_ID"
                          #
                          # Delete all Segment ID files and restart FFMPEG immediately
                          #
                          # FFMPEG is already paused. Pausing is required before deleting TS files to avoid that FFMPEG will continue to produce them
                          rm -f ${basepath}*.ts    # delete TS files before restarting FFMPEG to avoid that restart is quick and new files will be created before rm command finishes
                          # Do not check for PID change
                          restart_ffmpeg $SEGMENT_ID
                          break
                      else
                          log_info "   Deleting (modified $(millis_to_date $DEL_MOD_MILLIS)): $DEL_FILENAME"
                          rm -f $DEL_FILENAME
                          extract_ts_id $SEGMENT_ID "$DEL_FILENAME" # into $TS_ID
                          #
                          # Scheduling restart of FFMPEG is required only if the currently deleted TS file
                          # is sequentially after the last buffered TS file 
                          #
                          if [ $TS_ID -gt $LA_TS_ID ]; then
                              schedule_ffmpeg_restart_for_ts_id $SEGMENT_ID $TS_ID # will be scheduled for deleted TS file with the smallest $TS_ID
                          fi
                      fi
                  done
              fi
          else # [ $NO_SPACE_LEFT -eq 1 ]
              #
              # Retrieve allowed and tolerable space for this Segment ID
              #
              TS_SPACE_ALLOWED_PERC=${TS_SPACE_ALLOWED_PERC_ARRAY[$SEGMENT_ID]}
              TS_SPACE_TOLERABLE_PERC=${TS_SPACE_TOLERABLE_PERC_ARRAY[$SEGMENT_ID]}
              ([ "$TS_SPACE_ALLOWED_PERC" == "" ] || [ $TS_SPACE_ALLOWED_PERC -eq 0 ]) && TS_SPACE_ALLOWED_PERC=$TS_SPACE_ALLOWED_PERC_DEFAULT
              ([ "$TS_SPACE_TOLERABLE_PERC" == "" ] || [ $TS_SPACE_TOLERABLE_PERC -eq 0 ]) && TS_SPACE_TOLERABLE_PERC=$TS_TOLERABLE_SPACE_OVERRUN_PERC
              if [ $LA_FOUND -eq 1 ]; then # if last accessed (LA) is found (TS file with Last Accessed greater than Last Modified)

                if tracking_ts_inactive_seconds $SEGMENT_ID; then
                    #
                    # Finally some TS file is accessed so cancelling inactivity monitoring which would restart FFMPEG if none
                    # of the TS files were accessed for $TS_INACTIVITY_RESTART_SECONDS seconds
                    #
                    log_debug "Cancelling inactivity monitoring. TS files were not accessed for $(get_ts_inactive_seconds $SEGMENT_ID) seconds."
                    clear_ts_inactive_seconds $SEGMENT_ID # cancel inactivity monitoring
                fi
                #
                # Get the FFMPEG position starting from which TS files were created (FFMPEG argument -START_NUMBER)
                #
                get_ffmpeg_pos $SEGMENT_ID # into $FFMPEG_POS
                if [ "$FFMPEG_POS" != "" ]; then
                    FFMPEG_POS_PREV=$((FFMPEG_POS-1)) # store previous TS ID before last position change
                    datetime_diff_now "$FFMPEG_POS_TIME"
                    FFMPEG_POS_SECONDS=$DIFF_SECONDS # seconds since position change
                    FFMPEG_POS_FILENAME="$TRANSCODES_DIR/${SEGMENT_ID}${FFMPEG_POS}.ts"
                else
                    FFMPEG_POS_PREV=
                    FFMPEG_POS_SECONDS=
                    FFMPEG_POS_FILENAME=
                fi
                #
                # If last accessed file is not sequential to the previous "last accessed" file then
                # it means that player position has changed, and FFMPEG will delete all previous TS files
                # and start creating new ones for the new position.
                #
                # Here we want to perform a certain clean-up (like cancel FFMPEG restart if it was scheduled)
                #
                log_debug "Analyzing sequential and sequentially broken TS files starting with last buffered (in increasing sequence of TS ID)"
                #
                if [ "$LA_FOUND_TS_ID" == "" ]; then # we want to initialize some statistics when first time encountering LA file for each Segment ID
                    #
                    # Store time when buffering of the last buffered TS file started -
                    # client has just started to download the $LA_FILENAME file
                    #
                    store_ts_buffer_seconds $SEGMENT_ID
                    LA_FOUND_TS_ID=$LA_TS_ID                        # initialize this variable to avoid entering again in this IF block
                    store_last_accessed_ts_id $SEGMENT_ID $LA_TS_ID # should be in sync with LA_FOUND_TS_ID
                else
                    #
                    # Ignore if previous TS ID is the same as current TS ID, because it takes time for client
                    # player to read from the TS file (buffering) and it may take several loops in this script
                    # until client will buffer the next TS file
                    #
                    # NOTE: when client has paused the playback then buffering of the next TS file will happen
                    #       when playback resumes, so the measurement of buffering time will not be correct
                    #
                    if [ $LA_FOUND_TS_ID -ne $LA_TS_ID ]; then # Enter this IF block only once per each buffered TS file
                                                               # Using LA_FOUND_TS_ID to avoid enterinf this IF block for the very first buffered TS file
                        if [ $LA_TS_ID -eq $(($LA_FOUND_TS_ID + 1)) ]; then # TS file is sequential to the previous file
                            #
                            # Store time required to fully buffer the last TS file
                            #
#
# TODO: implement logic to ignore buffering time measurement when client paused and resumed playback -
#       deviation for more than 50% if happens once (not two times in a row) is a good sign that playback was resumed
#
                            update_ts_buffer_stats $SEGMENT_ID $(get_ts_buffer_seconds $SEGMENT_ID) $LA_FILESIZE
                            store_ts_buffer_seconds $SEGMENT_ID # re-set timer to measure buffering time for the next TS file
                        else
                            #
                            # Compare FFMPEG position with the last recorded position - if it differs then record new position for the first time
                            # Cancel scheduled FFMPEG restart/resume only once per position change
                            #
                            if ([ "$LAST_FFMPEG_POS_CHANGE" != "" ] && [ "$FFMPEG_POS" != "" ]) && [ $LAST_FFMPEG_POS_CHANGE != $FFMPEG_POS ]; then
                                SEGMENT_LAST_POS_CHANGE[$SEGMENT_ID] = $FFMPEG_POS
                                #
                                # Player position changed (not sequential buffering/playback)
                                #
                                log_info "Playback position has changed $LA_TS_ID <> $LA_FOUND_TS_ID +1"
                                log_trace "Cancelling FFMPEG restart if scheduled"
                                cancel_ffmpeg_restart_if_scheduled $SEGMENT_ID
                                log_trace "Cancelling FFMPEG resume if scheduled"
                                cancel_ffmpeg_resume_if_scheduled $SEGMENT_ID
                            fi
                            if tracking_ts_inactive_seconds $SEGMENT_ID; then
                                #
                                # Cancelling inactivity monitoring due to playback position change - we expect that new TS files
                                # are/will be created and there a new inactivity monitoring will be started if none of those files will be accessed
                                #
                                log_trace "Clearing inactivity monitoring"
                                clear_ts_inactive_seconds $SEGMENT_ID
                            fi
                            #
                            # Resetting stats is not needed because it is expected that
                            # at any playback position the TS file buffering will be similar.
                            # This else statement will not work for changing playback quality,
                            # because LA_TS_ID will be kept the same.
                            #
                            ## reset_ts_buffer_stats
                        fi
                        LA_FOUND_TS_ID=$LA_TS_ID                        # store the latest accessed TS ID
                        store_last_accessed_ts_id $SEGMENT_ID $LA_TS_ID # should be in sync with LA_FOUND_TS_ID
                    fi
                fi
                # VARIABLE:               # MEANING:
                # ----------------------- # ----------------------------------------------------------------------
                SEQ_LA_FOUND=0            # identifies if last buffered file is found when looping though TS files in sequential order (by filename)
                LAST_SEQ_TS_ID=$LA_TS_ID  # keep next TS file if it's TS ID is LAST_SEQ_TS_ID + 1 (subsequent TS ID is sequential to the previous without gaps)
                SIZE=0                    # accumulates TS file size to determine the directory space that they consume
                SIZE_PERC=0               # same as SIZE expressed in percentage of 90% or less from the total directory space
                DELETE_SUBSEQUENT=0       # variable used to process deletion of subsequent files when allowed space is exhausted
                DELETE_SUBSEQUENT_NO_RESTART=0 # if set to 1 FFMPEG restart will not be scheduled when TS file is deleted (used together with DELETE_SUBSEQUENT=1)
                DELETE_ONCE_NO_WAIT=0     # delete one file without waiting (alternative to sequential deletion), FFMPEG restart will not be scheduled
                DELETE_PREVIOUS_NO_WAIT=0 # delete previous TS file that is found before LA file without waiting
                DELETE_PREVIOUS_FILENAME= # stores filename to be deleted (delete all TS files before the last buffered, except the last one)
                DELETE_PREVIOUS_FILESIZE=
                DELETE_PREVIOUS_SIZE_PERC=
                DELETE_PREVIOUS_MOD_DATE=
                DELETE_PREVIOUS_MOD_TIME=
                LAST_BEFORE_LA_KEPT=0     # LA-1 was not deleted
                LAST_BEFORE_LA_FILENAME=  # LA-1 TS filepath
                LAST_BEFORE_LA_FILESIZE=  # LA-1 TS file size
                NEEDS_FFMPEG_RESUME=0
                #
                # Check if the current TS file is close enough to the earlier deleted TS file
                # There needs to be sufficient time for FFMPEG to restart and start producing new files
                # while buffering has not reached the deleted TS file
                #
                if ([ "$FFMPEG_POS" != "" ] && [ $FFMPEG_POS -le $TS_ID ]); then # if FFMPEG position is changed then do not restart/resume FFMPEG
                    restart_ffmpeg_if_scheduled "$SEGMENT_ID" $LA_TS_ID
                    if resume_ffmpeg_if_scheduled "$SEGMENT_ID" $LA_TS_ID; then
                        NEEDS_FFMPEG_RESUME=1
                    fi
                fi
                #
                # Reset TS file size statistics, because we want to collect the average size of all existing files
                #
                reset_ts_size_stats $SEGMENT_ID
                #
                # List TS filenames (with path) in ascending order, ordered as number ("10" is greater than "1")
                # Ignore 0-size files
                #
                # Remove path and Segment Id from filename, configure delimiter as "." (-t .) and sort part as #1 (-k 1)
                # Example output:
                #    8.ts 23170812 2023-02-11 23:07:04.921025804 +0000 2023-02-11 23:07:04.934025804 +0000
                #    9.ts 22483672 2023-02-11 23:07:05.591025813 +0000 2023-02-11 23:07:05.605025813 +0000
                #    10.ts 23596256 2023-02-11 23:07:06.259025822 +0000 2023-02-11 23:07:06.272025822 +0000
                #
                log_info "[$SEGMENT_ID] Listing/cleaning TS files sequentially before the LA file (TS ID < $LA_TS_ID):"
                log_trace "#LIST TS FILES ASCENDING# find $TRANSCODES_DIR -name \"$TS_PATTERN\" -type f ! -size 0 -exec stat -c '%n %s %x %y' {} \; 2>/dev/null | sed 's/'$TRANSCODES_DIR_ESCAPED'\/'$SEGMENT_ID'//' | sort -t . -k 1 -g"
                if trace_is_on; then find $TRANSCODES_DIR -name "$TS_PATTERN" -type f ! -size 0 -exec stat -c '%n %s %x %y' {} \; 2>/dev/null | sed 's/'$TRANSCODES_DIR_ESCAPED'\/'$SEGMENT_ID'//' | sort -t . -k 1 -g >> $CLEANUP_LOG 2>&1; echo "#" >> $CLEANUP_LOG; fi
                FFMPEG_ALREADY_PAUSED=0 # did FFMPEG process got paused in the for loop
                DELETE_SUBSEQUENT_INFO_ONCE=0 # report some info messages only once in log file to not clutter the log file
                FFMPEG_POS_INFO_ONCE=0 # report some info messages only once in log file to not clutter the log file
                for line in $(find $TRANSCODES_DIR -name "$TS_PATTERN" -type f ! -size 0 -exec stat -c '%n %s %x %y' {} \; 2>/dev/null | sed 's/'$TRANSCODES_DIR_ESCAPED'\/'$SEGMENT_ID'//' | sort -t . -k 1 -g); do
                    #
                    decompose_file_nsxy $line
                    SEQ_FILESIZE=$FILESIZE
                    SEQ_MOD_DATE=$MOD_DATE # %y
                    SEQ_MOD_TIME=$MOD_TIME # %y
                    SEQ_ACC_DATE=$ACC_DATE # %x
                    SEQ_ACC_TIME=$ACC_TIME # %x
                    #
                    # Convert sorted filename numeric part back to full filename
                    #
                    SEQ_FILENAME=$TRANSCODES_DIR/${SEGMENT_ID}$FILENAME # %n
                    #
                    # Start analyzing TS files sequentially (by TS ID) after the last accessed file ($LA_FILENAME)
                    #
                    if [ $DELETE_SUBSEQUENT -eq 0 ]; then
                        #
                        # Locate last accessed filename ($LA_FILENAME) in the list
                        #
                        if [ $SEQ_LA_FOUND -eq 0 ]; then # enter this block before the last accessed (buffered) TS file is found
                            #
                            if [ "$LA_FILENAME" == "$SEQ_FILENAME" ]; then # LA file is found
                                #
                                # Check if this TS file ($DELETE_PREVIOUS_TS_ID) is sequentially before previous (having sequence -1) from the last accessed
                                # file TS ID ($LA_TS_ID), otherwise delete the previous TS file
                                #
                                if [ "$DELETE_PREVIOUS_FILENAME" != "" ]; then
                                    #
                                    # Updating TS file size statistics
                                    #
                                    update_ts_size_stats $SEGMENT_ID $DELETE_PREVIOUS_FILESIZE
                                    #
                                    if [ $DELETE_PREVIOUS_TS_ID -eq $(($LA_TS_ID - 1)) ]; then # matching sequence - 1

                                        if [ $DELETE_PREVIOUS_NO_WAIT -eq 1 ]; then # delete if FFMPEG is creating files with a later sequence
                                            log_info "   Last TS file before LA file will be deleted (TS ID=$DELETE_PREVIOUS_TS_ID)"
                                        else
                                            log_info "   Keeping (LA-1): $DELETE_PREVIOUS_FILENAME"
                                            LAST_BEFORE_LA_KEPT=1
                                            LAST_BEFORE_LA_FILENAME=$DELETE_PREVIOUS_FILENAME
                                            LAST_BEFORE_LA_FILESIZE=$DELETE_PREVIOUS_FILESIZE
                                            DELETE_PREVIOUS_FILENAME= # keep the previous file
                                            SIZE=$(($SIZE + $DELETE_PREVIOUS_FILESIZE))                  # accumulate this and subsequent file sizes
                                            DELETE_PREVIOUS_SIZE_PERC=$(($SIZE*100/$DIR_SIZE))
                                        fi
                                    else
                                        #
                                        # Previous file which is stored in $DELETE_PREVIOUS_FILENAME is not sequential to the current LA_TS_ID
                                        # This can happen when position is changed, or when old files existed with the same Segment ID
                                        #
                                        log_info "   Flagging for deletion the last TS file before LA file (its TS ID is not in sequence $DELETE_PREVIOUS_TS_ID <> ($LA_TS_ID - 1))"
                                    fi
                                fi
                                #
                                # If FFMPEG starting position is later than the LA TS ID then delete this TS file without waiting
                                # because it won't be accessed by the client due to player position change
                                #
                                if ([ "$FFMPEG_POS" != "" ] && [ $FFMPEG_POS -gt $LA_TS_ID ]); then

                                    if [ $FFMPEG_POS_INFO_ONCE -eq 0 ]; then
                                        log_info "   Some files encountered with TS ID earlier than FFMPEG starting position (eg, TS ID=$LA_TS_ID) - they may be deleted if they were modified after last position change"
                                        FFMPEG_POS_INFO_ONCE=1
                                    fi
                                    #
                                    # Delete only if the TS file was created earlier than the last position change happened
                                    #
                                    if ([ "$SEQ_MOD_DATE $SEQ_MOD_TIME" \< "$FFMPEG_POS_TIME" ]); then
                                        #
                                        # If this is TS file just before new position (new LA-1) then ensure that file was accessed more
                                        # than x seconds ago because player may be still buffering it even though position was changed
                                        # (this might be the case when FFMPEG is restarted due to earlier TS file deletion, and it is
                                        # going to create TS file with TS ID next after the LA TS ID.
                                        #
                                        if [ $FFMPEG_POS -eq $(($LA_TS_ID + 1)) ]; then

                                            datetime_diff_now "$SEQ_ACC_DATE $SEQ_ACC_TIME"
                                            #
                                            if [ $DIFF_SECONDS -gt $KEEP_TS_MOD_SECONDS ]; then
                                                log_info "   Flagging for immediate (no wait) deletion TS file (TS ID=$LA_TS_ID) because FFMPEG starting position $FFMPEG_POS > $LA_TS_ID and TS file was last modified before position change $FFMPEG_POS_TIME and it was last accessed $DIFF_SECONDS > $KEEP_TS_MOD_SECONDS seconds"
                                                DELETE_ONCE_NO_WAIT=1 # do not wait $KEEP_TS_MOD_SECONDS
                                            else
                                                log_info "   Keeping (accessed $DIFF_SECONDS <= $KEEP_TS_MOD_SECONDS): $SEQ_FILENAME"
                                                DELETE_ONCE_NO_WAIT=0 # do not delete immediately
                                                SIZE=$(($SIZE + $SEQ_FILESIZE))    # accumulate this and subsequent file sizes
                                                SIZE_PERC=$(($SIZE*100/$DIR_SIZE)) # calculate accumulated file sizes percentage of 95% or less from the total directory space
                                            fi
                                        else
                                            log_info "   Flagging for immediate (no wait) deletion TS file (TS ID=$LA_TS_ID) because FFMPEG starting position $FFMPEG_POS > $LA_TS_ID and TS file was last modified before position change $FFMPEG_POS_TIME"
                                            DELETE_ONCE_NO_WAIT=1 # do not wait $KEEP_TS_MOD_SECONDS
                                        fi
                                    else
                                        log_info "   Keeping (modified >= POS TIME): $SEQ_FILENAME"
                                        SIZE=$(($SIZE + $SEQ_FILESIZE))    # accumulate this and subsequent file sizes
                                        SIZE_PERC=$(($SIZE*100/$DIR_SIZE)) # calculate accumulated file sizes percentage of 95% or less from the total directory space
                                    fi
                                    #
                                    # Do not set SEQ_LA_FOUND to continue deleting TS files until FFMPEG_POS file is encountered
                                    #
                                else
                                    SEQ_LA_FOUND=1                     # LA file found, check if subsequent TS files are in sequence with this TS ID
                                    SIZE=$(($SIZE + $SEQ_FILESIZE))    # accumulate this and subsequent file sizes
                                    SIZE_PERC=$(($SIZE*100/$DIR_SIZE)) # calculate accumulated file sizes percentage of 95% or less from the total directory space
                                fi
                                #
                                log_info "[$SEGMENT_ID] Listing/cleaning TS files sequentially after the LA file (TS ID > $LA_TS_ID):" # print only once in the loop
                                #
                                # Updating TS file size statistics
                                #
                                update_ts_size_stats $SEGMENT_ID $SEQ_FILESIZE
                                #
                            fi # [ "$LA_FILENAME" == "$SEQ_FILENAME" ]
                            #
                            # Delete all files that were created before the last accessed, except the last one
                            # Last Modified date/time of the TS file must be more than x seconds ago, otherwise
                            # we might delete a newly created TS when player position is changed to an earlier
                            # position, but buffering (file access) has not yet started
                            #
                            if [ "$DELETE_PREVIOUS_FILENAME" != "" ]; then
                                #
                                # Ensure that file was modified more than x seconds ago
                                #
                                if [ $DELETE_PREVIOUS_NO_WAIT -ne 1 ]; then
                                    datetime_diff_now "$DELETE_PREVIOUS_MOD_DATE $DELETE_PREVIOUS_MOD_TIME"
                                fi
                                if ([ $DELETE_PREVIOUS_NO_WAIT -eq 1 ] || [ $DIFF_SECONDS -gt $KEEP_TS_MOD_SECONDS ]); then
                                    if (trace_is_on && [ $DELETE_PREVIOUS_NO_WAIT -eq 1 ]); then
                                        log_trace "   Deleting <LA (no wait): $DELETE_PREVIOUS_FILENAME"
                                    else
                                        log_info "   Deleting <LA: $DELETE_PREVIOUS_FILENAME"
                                    fi
                                    rm -f "$DELETE_PREVIOUS_FILENAME"
                                else
                                    log_info "   Keeping ($DIFF_SECONDS <= $KEEP_TS_MOD_SECONDS seconds): $DELETE_PREVIOUS_FILENAME"
                                fi
                            fi # [ "$DELETE_PREVIOUS_FILENAME" != "" ]
                            #
                            # Set filepath of the TS file to be deleted until the last accessed TS file is found
                            #
                            if [ "$LA_FILENAME" != "$SEQ_FILENAME" ]; then
                                #
                                extract_ts_id $SEGMENT_ID "$SEQ_FILENAME" # into $TS_ID
                                #
                                # If FFMPEG starting position is equal to the current TS ID then keep this
                                # and subsequent sequential TS files regardless of what is the last accessed file (LA_TS_ID)
                                #
                                # EXAMPLE:    154 155 156 157 158 159 160 161 162 163 164
                                #             POS                         LA
                                #
                                # In above example FFMPEG starting position (POS=154) is equal to the TS file being checked here
                                #
                                # - if position was changed AFTER (newer than) the last accessed (LA=161) TS file was accessed (POS TIME newer/bigger >= LA TIME older/smaller), then
                                #   we need to treat TS file 154 as the potentially new LA file and start calculating used space from it
                                #
                                # - if position was changed BEFORE (older than) the last accessed (LA=161) TS file was accessed (POS TIME older/smaller < LA TIME newer/bigger), then
                                #   we just need to delete these old files 154 .. 159 which won't be buffered by the client any more
                                #
                                if ([ "$FFMPEG_POS" != "" ] && [ $FFMPEG_POS -eq $TS_ID ]); then # $FFMPEG_POS == $TS_ID

                                    if ([ ! "$FFMPEG_POS_TIME" \< "$LA_ACC_DATE $LA_ACC_TIME" ]); then # treat this TS ID as potentially new LA file (note the ! inside if)

                                        SEQ_LA_FOUND=1                     # keep this and subsequent sequential TS files
                                        #
                                        LA_TS_ID=$TS_ID                    # set this TS ID as last accessed in order to make correct space usage calculations
                                        LAST_SEQ_TS_ID=$TS_ID              # keep next TS file if it's TS ID is LAST_SEQ_TS_ID + 1
                                        #
                                        SIZE=$(($SIZE + $SEQ_FILESIZE))    # accumulate this and subsequent file sizes
                                        SIZE_PERC=$(($SIZE*100/$DIR_SIZE)) # calculate accumulated file sizes percentage of 90% or less from the total directory space
                                        #
                                        # Compare FFMPEG position with the last recorded position - if it differs then record new position for the first time
                                        # Cancel scheduled FFMPEG restart/resume only once per position change
                                        #
                                        if ([ "$LAST_FFMPEG_POS_CHANGE" != "" ] && [ "$FFMPEG_POS" != "" ]) && [ $LAST_FFMPEG_POS_CHANGE != $FFMPEG_POS ]; then
                                            SEGMENT_LAST_POS_CHANGE[$SEGMENT_ID] = $FFMPEG_POS
                                            #
                                            # Player position changed (not sequential buffering/playback)
                                            #
                                            log_info "Playback position has changed due to FFMPEG position change (but buffering is not yet started by the client)"
                                            log_trace "Cancelling FFMPEG restart if scheduled"
                                            cancel_ffmpeg_restart_if_scheduled $SEGMENT_ID
                                            log_trace "Cancelling FFMPEG resume if scheduled"
                                            cancel_ffmpeg_resume_if_scheduled $SEGMENT_ID
                                        fi
                                        #
                                        # Updating TS file size statistics
                                        #
                                        update_ts_size_stats $SEGMENT_ID $SEQ_FILESIZE
                                        #
                                        # Store time when buffering of the last buffered TS file started -
                                        # client has just started to download the $LA_FILENAME file
                                        #
                                        store_ts_buffer_seconds $SEGMENT_ID
                                        #
                                        # Do not update the LA_FOUND_TS_ID because we want that buffering is measured
                                        # starting from the moment when the TS file is accessed. Here we have encountered
                                        # that playback position has changed, but the new TS file for this position
                                        # was not yet accessed:
                                        #
                                        # Do not call: store_last_accessed_ts_id $SEGMENT_ID $LA_TS_ID # should be in sync with LA_FOUND_TS_ID
                                        #
                                        # Do not cancel ffmpeg restart or ffmpeg resume in here - this will be done in the next cycle of the
                                        # main loop where LA_FOUND_TS_ID will be compared to LA_TS_ID after the new TS file is accessed
                                        #
                                        continue # continue to keep DELETE_PREVIOUS_FILENAME variable empty
                                    fi
                                else
                                    if ([ "$FFMPEG_POS_PREV" != "" ] && [ $FFMPEG_POS_PREV -eq $TS_ID ]); then # $FFMPEG_POS == $TS_ID - 1
                                    
                                        if ([ ! "$FFMPEG_POS_TIME" \< "$LA_ACC_DATE $LA_ACC_TIME" ]); then # (note the ! inside if)
                                            #
                                            # We want to keep TS file of TS ID equal to FFMPEG position -1 (keep the LA-1 TS file)
                                            # but only in case if TS file with TS ID which is equal to FFMPEG starting position is going to become
                                            # the new last accessed (LA) TS file (see the previous IF block where [ $FFMPEG_POS -eq $TS_ID ]).
                                            #
                                            # This is quiet impossible scenario here when there will exist old TS file BEFORE the currently buffered (LA)
                                            # file, and position is changed to +1 of this old file
                                            #
                                            # In theory this is only possible when FFMPEG have created many TS files ahead of the currnetly buffered file
                                            # and playback position is changed to one of these TS files
                                            #
                                            log_info "   Keeping (FFMPEG POS-1): $SEQ_FILENAME"
                                            LAST_BEFORE_LA_KEPT=1
                                            LAST_BEFORE_LA_FILENAME=$SEQ_FILENAME
                                            LAST_BEFORE_LA_FILESIZE=$SEQ_FILESIZE
                                            DELETE_PREVIOUS_FILESIZE=$SEQ_FILESIZE
                                            DELETE_PREVIOUS_FILENAME=                        # keep the previous file
                                            SIZE=$(($SIZE + $SEQ_FILESIZE))                  # accumulate this and subsequent file sizes
                                            DELETE_PREVIOUS_SIZE_PERC=$(($SIZE*100/$DIR_SIZE))
                                            continue # continue to keep SEQ_FILENAME variable empty
                                        fi
                                    else
                                        #
                                        # If FFMPEG starting position is later than the current TS ID then
                                        # delete this TS file without waiting, because it won't be accessed by the client
                                        # Comparing to TS_ID + 1 in order to keep last file before FFMPEG position
                                        #
                                        if ([ "$FFMPEG_POS" != "" ] && [ $FFMPEG_POS -gt $(($TS_ID + 1)) ]); then # $FFMPEG_POS > $TS_ID
                                            #
                                            # Delete only if the TS file was created earlier than the last position change happened
                                            #
                                            if ([ "$SEQ_MOD_DATE $SEQ_MOD_TIME" \< "$FFMPEG_POS_TIME" ]); then # MOD TIME older/smaller < FFMPEG POS newer/bigger
                                                log_info "   Flagging for immediate (no wait) deletion TS file (TS ID=$TS_ID) because FFMPEG starting position $FFMPEG_POS > $TS_ID + 1 and TS file was modified before position change $FFMPEG_POS_TIME"
                                                DELETE_PREVIOUS_NO_WAIT=1 # do not wait $KEEP_TS_MOD_SECONDS
                                            else
                                                log_info "   Keeping (modified >= POS TIME): $SEQ_FILENAME"
                                            fi
                                        fi
                                    fi
                                fi
                                DELETE_PREVIOUS_TS_ID=$TS_ID
                                DELETE_PREVIOUS_FILENAME=$SEQ_FILENAME
                                DELETE_PREVIOUS_FILESIZE=$SEQ_FILESIZE
                                DELETE_PREVIOUS_MOD_DATE=$SEQ_MOD_DATE
                                DELETE_PREVIOUS_MOD_TIME=$SEQ_MOD_TIME
                                # DELETE_PREVIOUS_SIZE_PERC is not needed here
                                
                            fi # [ "$LA_FILENAME" != "$SEQ_FILENAME" ]

                        else # [ $SEQ_LA_FOUND -eq 0 ]

                            extract_ts_id $SEGMENT_ID "$SEQ_FILENAME" # into $TS_ID
                            #
                            # Updating TS file size statistics
                            #
                            update_ts_size_stats $SEGMENT_ID $SEQ_FILESIZE
                            #
                            if [ $(($LAST_SEQ_TS_ID + 1)) -eq $TS_ID ]; then # matching sequence + 1
                                #
                                # print the size of the kept previous TS file (LA-1) before the currently buffered TS file
                                # $DELETE_PREVIOUS_FILENAME is "" when LA-1 file was kept
                                #
                                if trace_is_on && ([ "$DELETE_PREVIOUS_FILENAME" == "" ] && [ "$DELETE_PREVIOUS_FILESIZE" != "" ]); then
                                    log_trace "Accumulated space used by TS files of Segment ID=${SEGMENT_ID} (TS ID=$(($LA_TS_ID - 1))) is ${DELETE_PREVIOUS_SIZE_PERC}% / ${TS_SPACE_ALLOWED_PERC}% allowed space"
                                    DELETE_PREVIOUS_FILESIZE= # print only once in this loop
                                fi
                                #
                                # print the size of the currently buffered TS file
                                # $SIZE and $SIZE_PERC still holds the percentage of the previous TS file
                                #
                                if trace_is_on && [ $LAST_SEQ_TS_ID -eq $LA_TS_ID ]; then
                                    log_trace "Accumulated space used by TS files of Segment ID=${SEGMENT_ID} (TS ID=$LA_TS_ID) is ${SIZE_PERC}% / ${TS_SPACE_ALLOWED_PERC}% allowed space"
                                fi
                                SIZE=$(($SIZE + $SEQ_FILESIZE))
                                SIZE_PERC=$(($SIZE*100/$DIR_SIZE))
                                log_trace "Accumulated space used by TS files of Segment ID=${SEGMENT_ID} (TS ID=$TS_ID) is ${SIZE_PERC}% / ${TS_SPACE_ALLOWED_PERC}% allowed space"
                                
                                if [ $SIZE_PERC -gt $TS_SPACE_ALLOWED_PERC ]; then # TS files size exceed allowed space
                                    #
                                    # Jellyfin client requires that at least two more TS files exist after the currently buffered TS file,
                                    # otherwise playback will stall. If there is not sufficient space to create more than two TS file after
                                    # the currently buffered (LA) file then delete the LA-1 file
                                    #
                                    # 101 102 103 104   101 = LA-1
                                    #     ^^^           102 = LA (buffered)
                                    #                   if less than LA+1 or LA+2 run over allowed space then delete LA-1 to allow creating/keeping LA+3
                                    #
                                    if [ $LAST_SEQ_TS_ID -eq $LA_TS_ID ] || \
                                       [ $(( $LAST_SEQ_TS_ID - 1 )) -eq $LA_TS_ID ]; then    # TS_ID = LA+2, and space is over allowed, delete LA-1 to allow creating/keeping LA+3

                                        if ([ $LAST_BEFORE_LA_KEPT -eq 1 ] && [ -f $LAST_BEFORE_LA_FILENAME ]); then # ensure that LA-1 file exists before re-calculating used space
                                            log_info "Exceeded allowed space with next TS file after the LA file! Deleting LA-1 TS file (TS ID=$(($LA_TS_ID-1))) to avoid playback getting stalled."
                                            log_info "   Deleting LA-1: $LAST_BEFORE_LA_FILENAME"
                                            rm -f "$LAST_BEFORE_LA_FILENAME"
                                            #
                                            SIZE=$(($SIZE - $LAST_BEFORE_LA_FILESIZE))
                                            SIZE_PERC=$(($SIZE*100/$DIR_SIZE))
                                            log_trace "   Accumulated space used by TS files of Segment ID=${SEGMENT_ID} after deleting TS ID=$((LA_TS_ID-1)) is ${SIZE_PERC}% / ${TS_SPACE_ALLOWED_PERC}% allowed space"
                                            LAST_BEFORE_LA_KEPT=0
                                        else
                                            log_warn "Exceeded allowed space. Used space is ${SIZE_PERC}%, allowed is ${TS_SPACE_ALLOWED_PERC}%. LA-1 TS file does not exist. Cannot free up more space for successful playback."
#
# TODO: determine if this SEGMENT has the largest TS file size, and if so then delete all the TS files for this segment
#       - in such case user has to lower the streaming bitrate to continue playing. Unfortunately there is no way to inform user about it
#
                                        fi
                                    fi
                                fi
                                #
                                # Check again the used space, because if LA-1 TS file was just deleted then used space was re-calculated
                                #
                                if [ $SIZE_PERC -gt $TS_SPACE_ALLOWED_PERC ]; then # TS files size exceed allowed space
                                    #
                                    # If FFMPEG position was changed after the LA file was accessed, and at least 3 seconds have passed
                                    # check if TS file with ID equal to position change ID is created, if it is not
                                    # then resume FFMPEG and delete all existing TS files which are older than FFMPEG position change -
                                    #
                                    # resumed FFMPEG will start producing files which will quickly fill-up all space, so we will delelete
                                    # all files in a loop until the TS file with ID equal to postition change ID is created
                                    #
                                    if ([ "$FFMPEG_POS" != "" ]) && \
                                       ([ $FFMPEG_POS_SECONDS -gt $FFMPEG_POS_TIME_STALL ]) && \
                                       ([ ! "$FFMPEG_POS_TIME" \< "$LA_ACC_DATE $LA_ACC_TIME" ]) && \
                                       ([ ! -f "$FFMPEG_POS_FILENAME" ]); then
                                        log_warn "FFMPEG position was changed more than $FFMPEG_POS_TIME_STALL seconds back."
                                        log_warn "TS file for the new position was not created and no TS file was accessed since then."
                                        log_warn "Freeing up space and resuming FFMPEG to try to speed up new TS file creation."
                                        rm -f $TRANSCODES_DIR/${TS_PATTERN}
                                        resume_ffmpeg $SEGMENT_ID
                                        i=1
                                        while [ $i -ge 0 ]; do # repeat loop maximum 2 times
                                            #
                                            # Need to delete files in sequential order to avoid deleting files with TS ID subsequent to changed position ID
                                            #
                                            log_trace "#LIST TS FILES ASCENDING# find $TRANSCODES_DIR -name \"$TS_PATTERN\" -type f -exec stat -c '%n' {} \; 2>/dev/null | sed 's/'$TRANSCODES_DIR_ESCAPED'\/'$SEGMENT_ID'//' | sort -t . -k 1 -g"
                                            if trace_is_on; then find $TRANSCODES_DIR -name "$TS_PATTERN" -type f -exec stat -c '%n' {} \; 2>/dev/null | sed 's/'$TRANSCODES_DIR_ESCAPED'\/'$SEGMENT_ID'//' | sort -t . -k 1 -g >> $CLEANUP_LOG 2>&1; echo "#" >> $CLEANUP_LOG; fi
                                            for d in $(find $TRANSCODES_DIR -name "$TS_PATTERN" -type f -exec stat -c '%n' {} \; 2>/dev/null | sed 's/'$TRANSCODES_DIR_ESCAPED'\/'$SEGMENT_ID'//' | sort -t . -k 1 -g); do
                                                DEL_FILENAME=$TRANSCODES_DIR/${SEGMENT_ID}$d # %n
                                                if [ "$DEL_FILENAME" == "$FFMPEG_POS_FILENAME" ]; then
                                                    break 2; # break while loop
                                                else
                                                    rm -f "$DEL_FILENAME"
                                                fi
                                            done
                                            ((i--))
                                            if [ $i -ge 0 ]; then # sleep only if while loop will be repeated
                                                sleep 0.2 # give time for FFMPEG to produce new files
                                            fi
                                        done
                                        log_trace "Cancelling FFMPEG restart if scheduled"
                                        cancel_ffmpeg_restart_if_scheduled $SEGMENT_ID
                                        log_trace "Cancelling FFMPEG resume if scheduled"
                                        cancel_ffmpeg_resume_if_scheduled $SEGMENT_ID
                                        #
                                        NEEDS_FFMPEG_RESUME=0 # already resumed
                                        #
                                        break; # stop listing files - they were deleted, will check again in the next loop cycle for this Segment ID
                                    else
                                        #
                                        # If FFMPEG resume was requested then it cannot be activated because there is not sufficient space
                                        # This will avoid resuming and immediately pausing again the process in each of this script cycle
                                        # when the process need to remain paused
                                        #
                                        if [ $NEEDS_FFMPEG_RESUME -eq 1 ]; then
                                            log_info "Scheduled resume of FFMPEG was requested, but got cancelled due to insufficient allowed space."
                                            NEEDS_FFMPEG_RESUME=0
                                        fi
                                        #
                                        # In order to avoid deleting TS file when space is just little above allowed,
                                        # TS files may overrun allowed space by additional percent of tolerable space
                                        #
                                        TS_TOTAL_SPACE_ALLOWED_PERC=$(($TS_SPACE_ALLOWED_PERC + $TS_SPACE_TOLERABLE_PERC))
                                        if [[ $SIZE_PERC -le $TS_TOTAL_SPACE_ALLOWED_PERC || $DIR_SPACE_USED_PERC -le 85 ]]; then
                                            #
                                            # TS files sizes are within tolerable space percent, or
                                            # TS files sizes are over allowed + tolerable space percent, but free space remaining is at least 15%
                                            #
                                            if [ $FFMPEG_ALREADY_PAUSED -eq 0 ]; then

                                                if [ $SIZE_PERC -le $TS_TOTAL_SPACE_ALLOWED_PERC ]; then
                                                    log_info "Pausing FFMPEG child processes due to used space (${SIZE_PERC}%) exceeds ${TS_SPACE_ALLOWED_PERC}% allowed, but it is still within tolerable ${TS_TOTAL_SPACE_ALLOWED_PERC}%:"
                                                else
                                                    log_info "Pausing FFMPEG child processes. Used space (${SIZE_PERC}%) exceeds ${TS_TOTAL_SPACE_ALLOWED_PERC}% allowed + tolerable space, however free space in directory is at least 15% remaining."
                                                fi
                                                pause_ffmpeg $SEGMENT_ID; RESULT=$?
                                                if [ $RESULT -eq 1 ]; then # do not schedule if FFMPEG was already paused (resume was already scheduled)
                                                    schedule_ffmpeg_resume_for_last_modified $SEGMENT_ID # smallest TS ID which was last modified within last second before pause
                                                fi
                                                FFMPEG_ALREADY_PAUSED=1 # do not try to pause again in this loop
                                            else
                                                if [ $SIZE_PERC -gt $TS_TOTAL_SPACE_ALLOWED_PERC ]; then
                                                    log_info "Used space (${SIZE_PERC}%) exceeds ${TS_TOTAL_SPACE_ALLOWED_PERC}% allowed + tolerable space, however free space in directory is at least 15% remaining and FFMPEG is already paused."
                                                fi
                                            fi
                                        else
                                            log_info "Due to used space (${SIZE_PERC}%) exceeds ${TS_TOTAL_SPACE_ALLOWED_PERC}% allowed + tolerable space, deleting subsequent TS files:"
                                            DELETE_SUBSEQUENT=1
                                            DELETE_SUBSEQUENT_NO_RESTART=0
                                            if [ $FFMPEG_ALREADY_PAUSED -eq 0 ]; then
                                                log_info "Pausing FFMPEG child processes to prevent from taking up more space. Scheduling resume in case if space is getting freed by deleting older TS files."
                                                pause_ffmpeg $SEGMENT_ID; RESULT=$?
                                                if [ $RESULT -eq 1 ]; then # do not schedule if FFMPEG was already paused (resume was already scheduled)
                                                    schedule_ffmpeg_resume_for_last_modified $SEGMENT_ID # smallest TS ID which was last modified within last second before pause
                                                fi
                                                FFMPEG_ALREADY_PAUSED=1 # do not try to pause again in this loop
                                            fi
                                        fi
                                    fi
                                fi
                                LAST_SEQ_TS_ID=$TS_ID
                            else                                        # sequence is broken
                                log_info ""
                                log_info "Deleting subsequent TS files because TS ID=$TS_ID is not sequential. Last sequential TS ID=$LAST_SEQ_TS_ID:"
                                ((LAST_SEQ_TS_ID++)) # set the TS ID to the TS file in sequence which is missing (first in the gap)
                                DELETE_SUBSEQUENT=1
                                DELETE_SUBSEQUENT_NO_RESTART=1 # do not schedule restart for sequentially broken subsequent TS files
                            fi
                        fi
                    fi # [ $DELETE_SUBSEQUENT -eq 0 ]

                    if [ $DELETE_ONCE_NO_WAIT -eq 1 ]; then
                        DELETE_ONCE_NO_WAIT=0 # reset back to default because must delete only one file
                        log_info "   Deleting (no wait): $SEQ_FILENAME"
                        rm -f $SEQ_FILENAME
                        # do not schedule FFMPEG restart
                    fi
                    if [ $DELETE_SUBSEQUENT -eq 1 ]; then
                        #
                        # NOTE: $TS_ID contains TS ID of the $SEQ_FILENAME file (it will only get set when DELETE_SUBSEQUENT=1)
                        #
                        if [ $DELETE_SUBSEQUENT_INFO_ONCE -eq 0 ]; then
                            log_info "Subsequent TS files will be deleted when they are modified more than $KEEP_TS_MOD_SECONDS seconds ago."
                            DELETE_SUBSEQUENT_INFO_ONCE=1
                        fi
                        datetime_diff_now "$SEQ_MOD_DATE $SEQ_MOD_TIME"
                        if [ $DIFF_SECONDS -gt $KEEP_TS_MOD_SECONDS ]; then
                            log_info "   Deleting ($DIFF_SECONDS > $KEEP_TS_MOD_SECONDS seconds): $SEQ_FILENAME"
                            rm -f $SEQ_FILENAME
                            if [ $DELETE_SUBSEQUENT_NO_RESTART -eq 0 ]; then # schedule FFMPEG restart when deleting sequentially broken subsequent TS files
                                [ $TS_ID -gt $LA_TS_ID ] && schedule_ffmpeg_restart_for_ts_id $SEGMENT_ID $LAST_SEQ_TS_ID # schedule restart for the first missing TS file
                            fi
                        else
                            log_info "   Keeping ($DIFF_SECONDS <= $KEEP_TS_MOD_SECONDS seconds): $SEQ_FILENAME"
                        fi
                    fi
                done
                #
                # Activate FFMPEG resume if required
                #
                if [ $NEEDS_FFMPEG_RESUME -eq 1 ]; then
                     log_info "Scheduled resume of FFMPEG is activated as requested."
                     resume_ffmpeg $SEGMENT_ID
                fi
              else
                #
                # No file was yet accessed. Monitor the size of existing TS files.
                #
                # Here we should not check files sequentially because we cannot know what to do with TS files that
                # are not sequential (1,2,3,4 -> 8,9,10,11) because we do not know which files are going to be
                # accessed by the client. So we just sum up the TS file sizes for specific Segment ID.
                #
                # If no file is accessed after X seconds, then restart FFMPEG (because the client may be missing
                # TS file that was accidently deleted - restarting FFMPEG would re-create this missing TS file)
                #
                shopt -u nullglob # otherwise if nullglob is set then du does not properly return size of non-existing filepath with wildcard
                log_trace "#DETERMINE SEGMENT TS SIZE# du -csb $TRANSCODES_DIR/$TS_PATTERN | tail -1 | awk '{print \$1}'"
                if trace_is_on; then du -csb $TRANSCODES_DIR/$TS_PATTERN | tail -1 | awk '{print $1}' >> $CLEANUP_LOG 2>&1; echo "#" >> $CLEANUP_LOG; fi
                SEGMENT_TS_SPACE_USED=$(du -csb $TRANSCODES_DIR/$TS_PATTERN | tail -1 | awk '{print $1}')
                shopt -s nullglob
                SEGMENT_TS_SPACE_PERC=$(($SEGMENT_TS_SPACE_USED*100/$DIR_SIZE))
                log_trace "Total space used by TS files of Segment ID=${SEGMENT_ID} is ${SEGMENT_TS_SPACE_PERC}% of directory size"
                
                if [ $SEGMENT_TS_SPACE_PERC -gt $TS_SPACE_ALLOWED_PERC ]; then # TS files size exceed allowed space
                    #
                    # There is tolerable space overrun in order to avoid deleting TS file
                    # when space is just little above allowed
                    #
                    TS_TOTAL_SPACE_ALLOWED_PERC=$(($TS_SPACE_ALLOWED_PERC + $TS_SPACE_TOLERABLE_PERC))
                    if [[ $SEGMENT_TS_SPACE_PERC -le $TS_TOTAL_SPACE_ALLOWED_PERC || $DIR_SPACE_USED_PERC -le 85 ]]; then
                        #
                        # TS files sizes are within allowed + tolerable space percent, or
                        # TS files sizes are over allowed + tolerable space percent, but free space remaining is at least 15%
                        #
                        if [ $SEGMENT_TS_SPACE_PERC -le $TS_TOTAL_SPACE_ALLOWED_PERC ]; then
                            log_info "Pausing FFMPEG child processes due to used space (${SEGMENT_TS_SPACE_PERC}%) exceeds ${TS_SPACE_ALLOWED_PERC}% allowed, but it is still within tolerable ${TS_TOTAL_SPACE_ALLOWED_PERC}%:"
                        else
                            log_info "Pausing FFMPEG child processes. Used space (${SEGMENT_TS_SPACE_PERC}%) exceeds ${TS_TOTAL_SPACE_ALLOWED_PERC}% allowed + tolerable space, however free space in directory is at least 15% remaining."
                        fi
                        pause_ffmpeg $SEGMENT_ID; RESULT=$?
                        if [ $RESULT -eq 1 ]; then # do not schedule if FFMPEG was already paused (resume was already scheduled)
                            schedule_ffmpeg_resume_for_last_modified $SEGMENT_ID # smallest TS ID which was last modified within last second before pause
                        fi
                    else
                        log_info "Due to used space (${SEGMENT_TS_SPACE_PERC}%) exceeds ${TS_TOTAL_SPACE_ALLOWED_PERC}% allowed + tolerable space, restarting FFMPEG and deleting all TS files for Segment ID=$SEGMENT_ID"
                        #
                        # Delete all Segment ID files and restart FFMPEG immediately
                        #
                        pause_ffmpeg $SEGMENT_ID # pause before deleting TS files to avoid that FFMPEG will continue to produce them
                        rm -f ${basepath}*.ts    # delete TS files before restarting FFMPEG to avoid that restart is quick and new files will be created before rm command finishes
                        restart_ffmpeg $SEGMENT_ID
                    fi
                fi
                if tracking_ts_inactive_seconds $SEGMENT_ID; then
                    INACTIVE_SECONDS=$(get_ts_inactive_seconds $SEGMENT_ID)
                    if [ $INACTIVE_SECONDS -ge $TS_INACTIVITY_RESTART_SECONDS ]; then
                        log_info "Due to inactivity when no TS file is accessed by client for $INACTIVE_SECONDS > $TS_INACTIVITY_RESTART_SECONDS seconds, restarting FFMPEG and deleting all TS files for Segment ID=$SEGMENT_ID"
                        #
                        # Delete all Segment ID files and restart FFMPEG immediately
                        #
                        pause_ffmpeg $SEGMENT_ID # pause before deleting TS files to avoid that FFMPEG will continue to produce them
                        rm -f ${basepath}*.ts    # delete TS files before restarting FFMPEG to avoid that restart is quick and new files will be created before rm command finishes
                        restart_ffmpeg $SEGMENT_ID
                        clear_ts_inactive_seconds $SEGMENT_ID
                    fi
                else
                    log_debug "Starting inactivity monitoring. If no TS file will be accessed in $TS_INACTIVITY_RESTART_SECONDS seconds then FFMPEG will be restarted and all TS files deleted for Segment ID=$SEGMENT_ID"
                    store_ts_inactive_seconds $SEGMENT_ID
                fi
              fi # [ $LA_FOUND -eq 1 ]

          fi # [ $NO_SPACE_LEFT -eq 1 ]

       else # compgen -G "${basepath}*.ts"
       
           #
           # If there is MPV file in transcodes directory for this Segment ID (partial transcode)
           # MP4 file is not possible to control - it will grow and consume all available space in transcodes directory
           # so we will kill FFMPEG process and truncate the MP4 file. We expect that player will signal the Jellfyin server
           # that there is problem with MP4 stream and the server will fallback to direct stream (not using transcodes directory)
           # or HLS stream (using TS files in transcodes directory).
           #
           if compgen -G "${basepath}.mp4" > /dev/null; then

              log_debug "--- Processing MKV file for Segment ID: $SEGMENT_ID --------";
              log_warn "WARNING: Space consumption for MP4 stream cannot be controlled - killing FFMPEG and deleting the stream to forece Jellyfin to fallback to other format.";

              if [ $INITIALIZING -eq 1 ]; then
                #
                # If pause file exists then delete it
                #
                PAUSE_FILEPATH=$SEMAPHORE_DIR/${SEGMENT_ID}.pause
                if [ -f $PAUSE_FILEPATH ]; then
                    log_warn "   Found PAUSE file for Segment ID=$SEGMENT_ID. Deleting PAUSE file.";
                    rm -f $PAUSE_FILEPATH
                fi
              fi
              log_warn "   Killing FFMPEG child processes for Segment ID=$SEGMENT_ID"
              signal_ffmpeg $SEGMENT_ID -SIGKILL
              #
              log_warn "   Truncating and deleting MP4 file: ${basepath}.mp4"
              :> ${basepath}.mp4 # truncate will ensure that MP4 is not using up space when after deletion it is held up in /proc/*/fd
              rm -f ${basepath}.mp4 # PID file will be deleted soon after when MP4 is not existing
              #
              ACTUAL_PIDS+=($SEGMENT_ID)
              ((ACTUAL_PID_COUNT++))

           else # compgen -G "${basepath}.mp4"

              #
              # No TS files exist for given Segment ID
              # Delete PID file if it was modified more than "n" seconds ago
              #
              if get_file_mod_date $f; then # else file was deleted unexpectedly
                  datetime_diff_now "$MOD_DATE $MOD_TIME"
                  if [ $DIFF_SECONDS -gt $KEEP_PID_MOD_SECONDS ]; then
                      basepath=${f%.*}
                      log_info "Deleting ${basepath}.* PID file and other resouces as no corresponding TS files exist. $DIFF_SECONDS > $KEEP_PID_MOD_SECONDS seconds since it was last modified."
                      rm -f ${basepath}.*
                  else
                      log_info "No corresponding TS files exist for $f, but keeping it because it was modified $DIFF_SECONDS <= $KEEP_PID_MOD_SECONDS seconds back."
                  fi
              fi
          fi
       fi
    done
    #
    # Searching for *.ts files which are without a corresponding PID file
    #
    # Populate array with existing Segment IDs
    #
    # NOTE! PID file may appear just before the loop, so then $ACTUAL_PIDS will not contain such PID inspite its existance
    #
    ignore_pattern=
    if [ $ACTUAL_PID_COUNT -gt 0 ]; then
        #for pid in ${ACTUAL_PIDS[@]}; do ignore_pattern="$ignore_pattern --ignore=\"$TRANSCODES_DIR/${pid}*.ts\""; done
        set -f
        for pid in ${ACTUAL_PIDS[@]}; do ignore_pattern="$ignore_pattern -not -name \"${pid}*\""; done
        set +f
    fi
    ACTUAL_PIDS_EXCLUDE=()
    REPORTED_ONCE=0 # avoid cluttering log file
    while true; do
        #
        FOUND=0
        #for f in $(ls $TRANSCODES_DIR/*.ts $ignore_pattern | head -1); do
        final_ignore_pattern=$ignore_pattern
        set -f
        for pid in ${ACTUAL_PIDS_EXCLUDE[@]}; do final_ignore_pattern="$final_ignore_pattern -not -name \"${pid}*\""; done
        set +f
        for f in $(eval "find $TRANSCODES_DIR -maxdepth 1 -name \"*.ts\" ${final_ignore_pattern:1} -not -type d -print -quit"); do # print one and quit
            if [ $REPORTED_ONCE -eq 0 ]; then
                ignore_pattern_text=$( [ "$final_ignore_pattern" == "" ] && echo ' (empty)' || echo "($final_ignore_pattern)" )
                log_trace "Searching for *.ts files (at least $KEEP_PID_MOD_SECONDS seconds old) without corresponding PID file, using ignore pattern: ${ignore_pattern_text:1}"
                log_trace "#LIST TS FILES WITH NO PID# eval \"find $TRANSCODES_DIR -maxdepth 1 -name \\\"*.ts\\\" ${final_ignore_pattern:1} -not -type d -print -quit\""
                if trace_is_on; then eval "find $TRANSCODES_DIR -maxdepth 1 -name \"*.ts\" ${final_ignore_pattern:1} -not -type d -print -quit" >> $CLEANUP_LOG 2>&1; echo "#" >> $CLEANUP_LOG; fi
                REPORTED_ONCE=1
            fi
            FOUND=1
            filename=${f##*/}           # d2777e84003e90808f59960e32442ceb1449.ts
            segment_id=${filename:0:32} # d2777e84003e90808f59960e32442ceb
            
            if value $segment_id in ACTUAL_PIDS_EXCLUDE; then
                continue;
            fi
            #
            # Need to test for TS file modification date to avoid situation when TS file was created just after ACTUAL_PIDS array was
            # updated. The ACTUAL_PIDS array does not include Segment IDs which do not have TS files. So now when TS file is created,
            # but its Segment ID may be missing in ACTUAL_PIDS array, then without checking that the TS file was modified X seconds
            # back we would mistakenly delete the TS file.
            #
            # Above find command returns randomly the first TS file it finds. It does not matter which file we test for modification date.
            #
            if get_file_mod_date $f; then # else file was deleted unexpectedly
                datetime_diff_now "$MOD_DATE $MOD_TIME"
                if [ $DIFF_SECONDS -gt $KEEP_PID_MOD_SECONDS ]; then
                    log_info "Deleting TS files for Segment ID=$segment_id because corresponding PID file is not found. Waited for $DIFF_SECONDS > $KEEP_PID_MOD_SECONDS seconds."
                    rm -f $TRANSCODES_DIR/${segment_id}*.ts;
                else
                    log_info "Keeping TS files for Segment ID=$segment_id even though PID file does not exist, because files were modified $DIFF_SECONDS <= $KEEP_PID_MOD_SECONDS seconds back."
                    #
                    # Because we need to wait until TS files modification date/time is getting a few seconds old, then to avoid end-less loop we
                    # add the Segment ID to EXCLUDE list
                    #
                    ACTUAL_PIDS_EXCLUDE+=($segment_id)
                fi
            fi
        done
        [ $FOUND -eq 1 ] || break # break when there are no more TS files without corresponding PID file
    done
    #
    # Calculate directory space in percentage that is allowed to use per each Segment ID
    # If there is only one Segment ID then use the default percentage (otherwise it will use 90% from the total size of directory)
    #
    if [ $ACTUAL_PID_COUNT -gt 0 ]; then
        #
        # Reserve space for additional future PID, and additional tolerable space
        # We use 90% of the total space, leaving 10% for accidental TS files left from previous playback
        # (for example, when changing playback position, there will exist old and new TS files for some moment)
        #
        if ([ "$TS_SPACE_RESERVED_MAX_DIVIDER" != "" ] && [ $ACTUAL_PID_COUNT -eq $TS_SPACE_RESERVED_MAX_DIVIDER ]); then
            TS_SPACE_RESERVED_DIVIDER=0
            TS_SPACE_RESERVED=$(( DIR_SIZE*5/100 )) # 5% for tolerable space
            TS_SPACE_RESERVED_PERC=5
        else
            TS_SPACE_RESERVED_DIVIDER=$(max $((ACTUAL_PID_COUNT + 1)) $TS_SPACE_RESERVED_MIN_DIVIDER) # MAX( PID+1 , MIN_DIVIDER )
            TS_SPACE_RESERVED=$(( $(( DIR_SIZE*95/100 )) / $TS_SPACE_RESERVED_DIVIDER )) # divide 95% of total directory size with number of PIDs+1, but minimum $TS_SPACE_RESERVED_DIVIDER
            TS_SPACE_RESERVED_PERC=$(div_roundup $(( TS_SPACE_RESERVED*100 )) $DIR_SIZE)
        fi
        #TS_SPACE_RESERVED=$(div_roundup $(( DIR_SIZE*95/100 )) $TS_SPACE_RESERVED_DIVIDER ) # divide 95% of total directory size with number of PIDs+1, but minimum $TS_SPACE_RESERVED_DIVIDER
        REMAINING_DIR_SIZE=$(( DIR_SIZE*95/100 - TS_SPACE_RESERVED ))           # 95% directory size without reserved space
        REMAINING_DIR_SIZE_PERC=$(( 95 - TS_SPACE_RESERVED_PERC ))
        #
        TOTAL_TS_AVG_SIZE=0
        TOTAL_TS_SPACE_USED_SIZE=0
        #
        # Re-define TS_SPACE_ALLOWED_PERC to remove any historical Segment IDs
        #
        unset TS_SPACE_ALLOWED_PERC_ARRAY
        unset TS_SPACE_TOLERABLE_PERC_ARRAY
        declare -A TS_SPACE_ALLOWED_PERC_ARRAY
        declare -A TS_SPACE_TOLERABLE_PERC_ARRAY
        #
        # Determine relational percentage for each Segment ID based on its average TS file size -
        # larger average TS file size requires more space
        #
        for pid in ${ACTUAL_PIDS[@]}; do
            TS_AVG_SIZE=$(get_ts_avg_size "$pid")  # average existing TS file size for this Segment ID
            if [ $TS_AVG_SIZE -eq 0 ]; then                                        # if statistics about TS file size is not yet collected then use default number
                TS_AVG_SIZE=$TS_AVG_SIZE_DEFAULT
            fi
            TS_PATTERN=${pid}*.ts
            TS_SPACE_ALLOWED_PERC_ARRAY["$pid"]=$TS_AVG_SIZE                    # temporary use TS_SPACE_ALLOWED_PERC_ARRAY array to store average space used
            (( TOTAL_TS_AVG_SIZE += TS_AVG_SIZE ))
        done
        for pid in ${ACTUAL_PIDS[@]}; do
            TS_AVG_SIZE=${TS_SPACE_ALLOWED_PERC_ARRAY[$pid]}
            TS_SPACE_ALLOWED_PERC_ARRAY["$pid"]=$(( TS_AVG_SIZE * REMAINING_DIR_SIZE_PERC / $TOTAL_TS_AVG_SIZE ))
            TS_SPACE_TOLERABLE_PERC_ARRAY["$pid"]=$(( TS_AVG_SIZE * TS_SPACE_RESERVED_PERC / $TOTAL_TS_AVG_SIZE ))
        done
    else
       #
       # $ACTUAL_PID_COUNT == 0 means that there is not Segment file having TS files, but there may exist Segment files without TS files
       #
       if [ "$ACTUAL_SEGMENTS_ARRAY" == "" ]; then # no PID file exists
           #
           # Monitor time of inactivity when no PID file is created
           #
           if [ $CLEANUP_INACTIVITY_SHUTDOWN_COUNTER -eq -1 ]; then
              log_info "Activating cleanup script inactivity monitor. The script will shutdown after $CLEANUP_INACTIVITY_SHUTDOWN_SECONDS seconds of inactivity."
              CLEANUP_INACTIVITY_SHUTDOWN_COUNTER=$SECONDS # activate counter
           else
              if [ $CLEANUP_INACTIVITY_SHUTDOWN_COUNTER -le -2 ]; then # cleanup script shutdown is in progress
                 if [ ! -f $CLEANUP_SHUTDOWN ]; then # shutdown flag file was removed - cancelling shutdown
                    log_info "Shutdown flag file was removed - cancelling shutdown"
                    CLEANUP_INACTIVITY_SHUTDOWN_COUNTER=-1 # deactivate cleanup script shutdown inactivity monitor
                    echo $$ > $CLEANUP_PID # update timestamp of the PID file to signal other clean up processes that this script is still active
                 else
                    #
                    # Verify how many seconds shutdown is in progress
                    #
                    if [ $(($SECONDS - $CLEANUP_INACTIVITY_SHUTDOWN_COUNTER*(-1) )) -ge 5 ]; then
                       if [ -f $CLEANUP_PID ]; then
                          rm -f $CLEANUP_PID
                          if [ -f $CLEANUP_PID ]; then
                            log_warn "Failed to delete PID file $CLEANUP_PID"
                          fi
                       fi
                       if [ -f $CLEANUP_SHUTDOWN ]; then
                          rm -f $CLEANUP_SHUTDOWN
                          if [ -f $CLEANUP_SHUTDOWN ]; then
                             log_warn "Failed to delete shutdown flag file $CLEANUP_SHUTDOWN"
                          fi
                       fi
                       echo $$ > $CLEANUP_STOPPED
                       log_info "Shutdown completed"
                       exit 0
                    fi
                 fi
              else
                  if [ $(($SECONDS - $CLEANUP_INACTIVITY_SHUTDOWN_COUNTER)) -ge $CLEANUP_INACTIVITY_SHUTDOWN_SECONDS ]; then
                     log_info "Cleanup script shutdown is activated because of inactivity during last $CLEANUP_INACTIVITY_SHUTDOWN_SECONDS seconds."
                     CLEANUP_INACTIVITY_SHUTDOWN_COUNTER=$(($SECONDS*(-1))) # initialize shutdown (wait some time to signal that cleanup script is exitting)
                     log_info "Shutdown flag file is created - delete the flag file to cancel the shutdown"
                     echo $$ > $CLEANUP_SHUTDOWN
                     if [ ! -f $CLEANUP_SHUTDOWN ]; then
                        log_warn "Failed to create the shutdown flag file, exitting immediately!"
                        exit 0
                     fi
                  fi
              fi
           fi
       fi
    fi
    # delete all 0 size files in transcodes directory (created with 0 size due to lack of free space)
    # such files will cause HLS player to stall during playback
    # only files created more than 30 seconds ago (0.5 of minute) will be deleted (to avoid deleting just created file)
    if trace_is_on; then
        RESULT=$(find $TRANSCODES_DIR -size 0 -name '*.ts' -type f -mmin +$((3/60)) -print 2>&1)
        if [ "$RESULT" != "" ]; then # print to log only when there are useful messages
            log_trace "#DELETE 0-SIZE FILES# find $TRANSCODES_DIR -size 0 -name '*.ts' -type f -mmin +$((3/60)) #-delete"
            echo "$RESULT" >> $CLEANUP_LOG; echo "#" >> $CLEANUP_LOG;
        fi
    fi
    find $TRANSCODES_DIR -size 0 -name '*.ts' -type f -mmin +$((3/60)) -delete
    #
    # Perform array maintenance - delete unused array elements (Segments that are no longer active)
    #
    if [ $(($SECONDS - $REMOVE_UNUSED_SEGMENTS_LAST)) -ge $REMOVE_UNUSED_SEGMENTS_INTERVAL ]; then
        log_info "MAINTENANCE TASK: Clean-up unused array elements"
        remove_unused_segments ACTUAL_SEGMENTS_ARRAY
        REMOVE_UNUSED_SEGMENTS_LAST=$SECONDS
    fi
    #
    # Cleanup (truncate) files that were deleted in transcoding directory. When FFMPEG process is paused without finishing writting a file (without
    # properly closing the file), and the file gets deleted by this clean-up script, then such file may not be cleaned/released by OS automatically -
    # such files will still consume space in transcoding directory (which cna be observed using df command) even when the transcoding directory is
    # completely empty (using ls command).
    #
    if [ $(($SECONDS - $CLEANUP_DELETED_FILES_LAST)) -ge $CLEANUP_DELETED_FILES_INTERVAL ]; then
        log_info "MAINTENANCE TASK: Clean-up deleted TS files in transcoding directory"
        if [ $USER_ID -eq 0 ]; then
            log_info "WARNING: RUNNING SCRIPT UNDER ROOT USER. Deleted files without read permission which were created by Jellyfin user will not be listed."
        fi
        log_trace "#CLEAN DELETED TS FILES# find - /proc/*/fd -type l -ls 2>&1 | grep $TRANSCODES_DIR/.*.ts.*\(deleted\)$"
        #
        shopt -u nullglob # disable nullglob otherwise grep using wildcard will fail
        #
        if trace_is_on; then eval "find - /proc/*/fd -type l -ls 2>&1 | grep $TRANSCODES_DIR/.*.ts.*\(deleted\)$" >> $CLEANUP_LOG 2>&1; echo "#" >> $CLEANUP_LOG; fi

        TOTAL_FILESIZE=0
        for fdeleted in $(find - /proc/*/fd -type l -ls 2>&1 | grep $TRANSCODES_DIR/.*.ts.*\(deleted\)$); do
            #
            # fdeleted sample:
            # 404024492      0 l-wx------   1 1000     users          64 Mar 20 13:44 /proc/4506/fd/29 -> /config/transcodes/c17239ef2609c0a7d5caa57ccac3741f15.ts\ (deleted)
            #
            t=$(echo $fdeleted | awk '{printf substr($13, 1, length($13)-1)" "} {cmd="stat -Lc \"%x %n %s\" " $11; system(cmd) 1>/dev/null}')
            #
            # t sample: /config/transcodes/c17239ef2609c0a7d5caa57ccac3741f15.ts 2023-03-19 19:43:09.582860699 +0000 /proc/4506/fd/29 36438016
            #
            DELETED_TS_FILEPATH=${t%% *}; t=${t#* } # /config/transcodes/c17239ef2609c0a7d5caa57ccac3741f15.ts
            [[ "$DELETED_TS_FILEPATH" =~ ${TRANSCODES_DIR_ESCAPED}\/(................................)([0-9]+).ts ]]
            DELETED_TS_SEGMENT_ID=${BASH_REMATCH[1]}
            DELETED_TS_ID=${BASH_REMATCH[2]}
            #
            # Truncate deleted TS file only if PID file of the segment is deleted. This will ensure that
            # clean-up script will not delete a file which may still be accessed.
            #
            if ! value $DELETED_TS_SEGMENT_ID in ACTUAL_SEGMENTS_ARRAY; then

                DELETED_TS_ACC_DATE=${t%% *}; t=${t#* } # 2023-03-19
                DELETED_TS_ACC_TIME=${t%% *}; t=${t#* } # 19:43:09.582860699
                t=${t#* }                               # ignore +0000
                DELETED_FD_FILEPATH=${t%% *}; t=${t#* } # /proc/4506/fd/29
                DELETED_TS_FILESIZE=${t%% *}            # 36438016
                
                if [ $DELETED_TS_FILESIZE -eq 0 ]; then # skip files that are already truncated to 0 size
                    log_info "   Deleted file $DELETED_TS_FILEPATH is already truncated (0 bytes, $DELETED_FD_FILEPATH)"
                else

                    datetime_diff_now "$DELETED_TS_ACC_DATE $DELETED_TS_ACC_TIME"
                    if [ $DIFF_SECONDS -gt $CLEANUP_DELETED_FILES_ACC_SECONDS ]; then # if file was not accessed for more than X seconds

                        log_info "   Truncating deleted file $DELETED_TS_FILEPATH (releasing $DELETED_TS_FILESIZE bytes, $DELETED_FD_FILEPATH)"
                        : > $DELETED_FD_FILEPATH # truncate file
                        ((TOTAL_FILESIZE += DELETED_TS_FILESIZE))
                    else
                        log_info "   Keeping deleted file $DELETED_TS_FILEPATH (using $DELETED_TS_FILESIZE bytes, $DELETED_FD_FILEPATH) because $DIFF_SECONDS <= $CLEANUP_DELETED_FILES_ACC_SECONDS seconds since it was last accessed"
                    fi
                fi
            fi
        done
        log_info "Released $TOTAL_FILESIZE bytes"
        CLEANUP_DELETED_FILES_LAST=$SECONDS
        #
        shopt -s nullglob # enable nullglob for other commands to work
    fi
    #
    # Perform maintenance for abendoned FFMPEG processes whose parent (FFMPEG WRAP script) was terminated by Jellyfin, but
    # process is still paused (state = T). Such process may be counted as active by the graphics card and utilize its limited
    # number of allowed processes. FFMPEG will fail with below error in the log file for NVIDIA graphics card when running out
    # of allowed limit of active processes:
    #
    #    [h264_nvenc @ 0x557de1d96540] OpenEncodeSessionEx failed: out of memory (10): (no details)
    #    Error initializing output stream 0:0 -- Error while opening encoder for output stream #0:0 - maybe incorrect parameters such as bit_rate, rate, width or height
    #
    # NOTE: When FFMPEG WRAP script is terminated then the FFMPEG child process will change its parent to process with PID=1, becoming
    # a zombie process (with process state = Z). If Jellyfin is running in a Docker container then by default the PID=1 of container
    # is Jellyfin. Jellyfin process does not perform cleanup (removal) of zombie proceses from the process table unlike it is done
    # by init process or tini. Use --init for docker run command to install init process with PID=1 so that it properly removes
    # terminated FFMPEG processes from process table.
    #
    if [ $(($SECONDS - $CLEANUP_ABENDONED_PROCESSES_LAST)) -ge $CLEANUP_ABENDONED_PROCESSES_INTERVAL ]; then
        log_info "MAINTENANCE TASK: Clean-up abendoned and sleeping FFMPEG processes (with status = T)"
        log_trace "#CLEAN ABENDONED FFMPEG PROCESSES# ps -o pid=,state=,comm= -p 1 --ppid 1 --forest | awk '(\$2~/^T/ && \$3~/^ffmpeg/) { print \$1 }'"
        if trace_is_on; then eval "ps -o pid=,state=,comm= -p 1 --ppid 1 --forest | awk '(\$2~/^T/ && \$3~/^ffmpeg/) { print \$1 }'" >> $CLEANUP_LOG 2>&1; echo "#" >> $CLEANUP_LOG; fi
        for pid in $(ps -o pid=,state=,comm= -p 1 --ppid 1 --forest | awk '($2~/^T/ && $3~/^ffmpeg/) { print $1 }'); do
           log_info "   Killing process $pid"
           kill -9 $pid;
        done
        CLEANUP_ABENDONED_PROCESSES_LAST=$SECONDS
    fi
    #
    # log filesize maintenance every 5 minutes (300 seconds)
    #
    if [ $(($SECONDS - CLEANUP_LOG_MAXSIZE_COUNTER)) -ge 300 ]; then
        CLEANUP_LOG_SIZE=$(stat -c%s $CLEANUP_LOG)
        if [ $CLEANUP_LOG_SIZE -gt $CLEANUP_LOG_MAXSIZE ]; then
            echo "Transcoding cleanup log file maintenance. Size has reached $CLEANUP_LOG_SIZE bytes so the log file will be truncated"
            :> $CLEANUP_LOG
            log_print_config # print information at the top of the log file
        fi
        CLEANUP_LOG_MAXSIZE_COUNTER=$SECONDS
    fi

    [ $INITIALIZING -eq 1 ] && INITIALIZING=0 # initialization is completed
    sleep 0.1
done

exit $?