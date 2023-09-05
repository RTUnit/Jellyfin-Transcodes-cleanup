#!/bin/bash
#
# Customization
#
TRANSCODES_DIR=/config/transcodes
SEMAPHORE_DIR=/config/semaphore # use RAM drive for FFMPEG transcoding PID and PAUSE files
LIST_TS_FILES_FIRST=5 # list only first 12 TS files when total file count exceeds LIST_TS_FILES_FIRST+LIST_TS_FILES_LAST
LIST_TS_FILES_LAST=3   # list only last   3 TS files when total file count exceeds LIST_TS_FILES_FIRST+LIST_TS_FILES_LAST
COLLECT_TS_PERF_STATS_SECONDS=5 # collect TS file creation performance statistics every 5 seconds
SCREEN_WIDTH=70 # screen line width
#
# Do not change below
#
SECONDS=0 # reset timer
unset pause_seconds
declare -A pause_seconds
TRANSCODES_DIR_ESCAPED=${TRANSCODES_DIR//\//\\\/} # convert "/config/transcodes" to "\/config\/transcodes"
VERSION=1.1

function datetime_diff_now {
    DIFF_SECONDS=$(( $(date "+%s") - $(date -d "$1" "+%s") ))
}

function get_file_mod_date {
    t=$(stat -c '%y' $1 2>&1) # 2>&1 - error to stdout
    if [ "${t:0:5}" == "stat:" ]; then # stat: cannot statx 'test.txt': No such file or directory
        [ 1 != 1 ] # return false
    else
        MOD_DATE=${t%% *}; t=${t#* }
        MOD_TIME=${t%% *} # return true
    fi
}

PRINT_COMMANDS=
LIST_TS_FILES_TOTAL=$((LIST_TS_FILES_FIRST + LIST_TS_FILES_LAST))
LIST_TS_FILES_DOTS=$((LIST_TS_FILES_FIRST + 1))

unset buffs_icon        # store icon index for animated display when client is downloading TS file
declare -A buffs_icon
unset play_icon        # store icon index for animated display when playing TS file
declare -A play_icon
unset load_icon        # store icon index for animated display when loading performance data
declare -A load_icon
unset ts_perf           # used for statistics to calculate TS file creation speed
declare -A ts_perf

function buf {
    DEFAULT_IFS=$IFS
    IFS=$'\n' # this will make FOR parsing each line instead of each whitespace
    declare -A buffs
    declare -A downs
    declare -A playb
    local buffered_id=
    local segment_id=
    local size_max_len=0
    for line in $(find $TRANSCODES_DIR -name "*.ts" -type f ! -size 0 -exec stat -c '%x %y %n' {} \; 2>/dev/null | sort -n -r); do
        local t=$line
        local ACC_DATE=${t%% *}; t=${t#* }
        local ACC_TIME=${t%% *}; t=${t#* }
        t=${t#* } # ignore +0000
        local MOD_DATE=${t%% *}; t=${t#* }
        local MOD_TIME=${t%% *}; t=${t#* }
        t=${t#* } # ignore +0000
#        local FILESIZE=${t%% *}; t=${t#* }
        local FILENAME=${t%% *}
        [[ "$FILENAME" =~ $TRANSCODES_DIR_ESCAPED/(................................)([0-9]+).ts ]]
        segment_id=${BASH_REMATCH[1]}
        buffered_id=${BASH_REMATCH[2]}

        if [ "${buffs[$segment_id]}" == "" ]; then
            if [ "$ACC_DATE $ACC_TIME" \> "$MOD_DATE $MOD_TIME" ]; then
                datetime_diff_now "$ACC_DATE $ACC_TIME"
                if [[ $DIFF_SECONDS -le 1 ]]; then # if accessed within last second then consider that TS file is still being downloaded
                    buffs[$segment_id]=$buffered_id
                    local buffn=${buffs_icon[$segment_id]%% *}
                    if [[ "$buffn" != "$buffered_id" ]]; then
                        buffs_icon[$segment_id]="$buffered_id 0"
                    fi
                else
                    if [[ "${downs[$segment_id]}" == "" ]]; then 
                        downs[$segment_id]=$buffered_id # played currently by the client
                    else
                        playb[$segment_id]=$buffered_id # already downloaded by client, but not played yet
                    fi
                fi
            fi
        else
            if [ "${downs[$segment_id]}" == "" ]; then
                if [ "$ACC_DATE $ACC_TIME" \> "$MOD_DATE $MOD_TIME" ]; then
                    datetime_diff_now "$ACC_DATE $ACC_TIME"
                    if [[ $DIFF_SECONDS -gt 1 ]]; then # if accessed within last second then consider that TS file is still being downloaded
                        downs[$segment_id]=$buffered_id # played currently by the client
                    fi
                fi
            fi
        fi
    done

    declare -A array
    local line=
    declare -A last_ts

    for line in $(find $TRANSCODES_DIR -name "*.ts" -type f ! -size 0 -exec stat -c '%n %s %x %y' {} \; 2>/dev/null | sed 's/'$TRANSCODES_DIR_ESCAPED'\/\(................................\)\(.*\)/\2 \1/' | sort -t . -k 1 -g); do
        local ts_name=${line%% *}; line=${line#* }
        local ts_size=${line%% *}
        local ts_size_fmt=$(awk -v n=$ts_size 'BEGIN {printf "%.2f", (n/1024/1024)}')"•MB"
        segment_id=${line##* }
        [[ "$ts_name" =~ ^([0-9]+).ts ]]
        local ts_id=${BASH_REMATCH[1]}
        local buffn=${buffs[$segment_id]%% *}
        if [ "$ts_id" == "$buffn" ]; then
            local idx=${buffs_icon[$segment_id]#* }
            idx=$((idx + 1))
            case $idx in
                1) is_buffering="□□□•serving..." ;;
                2) is_buffering="■□□•serving..." ;;
                *) is_buffering="■■□•serving..."; idx=0 ;;
            esac
            buffs_icon[$segment_id]="$buffn $idx"
        else
            is_buffering=
        fi
        [ "$ts_id" == "${downs[$segment_id]}" ] && is_buffering="■■■•served"
        if ([ "$ts_id" == "${playb[$segment_id]}" ] || ([ "$ts_id" == "${downs[$segment_id]}" ] && [ "${playb[$segment_id]}" == "" ])); then
            local idx=${play_icon[$segment_id]}; [ "$idx" == "" ] && idx=0
            ((idx ++))
            case $idx in
                1) icon_fmt="►••" ;;
                2) icon_fmt="►••" ;;
                3) icon_fmt="►►•" ;;
                4) icon_fmt="►►•" ;;
                5) icon_fmt="►►►" ;;
                6) icon_fmt="►►►" ;;
                7) icon_fmt="•►►" ;;
                8) icon_fmt="•►►" ;;
                9) icon_fmt="••►" ;;
               10) icon_fmt="••►" ;;
               11) icon_fmt="•••" ;;
                *) icon_fmt="•••"; idx=0 ;;
            esac
            play_icon[$segment_id]="$idx"
            is_buffering="$icon_fmt•playback"
        fi
        array[$segment_id]="${array[$segment_id]} $ts_id••$ts_size_fmt••$is_buffering"
        last_ts[$segment_id]=$ts_id
    done
    files=()
    local version_printed=0
    for segment_id in ${!array[@]}; do
        local PID_FILEPATH=$SEMAPHORE_DIR/$segment_id.pid
        local segment_pid=$(head -1 $PID_FILEPATH 2>/dev/null)
        local PAUSE_FILEPATH=$SEMAPHORE_DIR/$segment_id.pause
        local segment_state=$(head -1 $PAUSE_FILEPATH 2>/dev/null)
        local sec=
        if [ "$segment_state" != "" ]; then
            if [ "$segment_pid" == "$segment_state" ]; then

                sec=${pause_seconds["$segment_id"]}
                if [ "$sec" == "" ]; then
                    sec=$SECONDS
                fi
                if get_file_mod_date $PAUSE_FILEPATH; then # else file was deleted unexpectedly
                    datetime_diff_now "$MOD_DATE $MOD_TIME"
                    segment_state="PAUSED $DIFF_SECONDS"
                else
                    segment_state="PAUSED $(($SECONDS-$sec))"
                fi
            else
                segment_state="RUNNING" # current PID is not paused
            fi
        else
            segment_state="RUNNING" # no PAUSE file
        fi
        pause_seconds["$segment_id"]=$sec
        local POS_FILEPATH=$SEMAPHORE_DIR/$segment_id.pos
        local segment_pos=$(head -1 $POS_FILEPATH)
        if [ "$segment_pos" != "" ]; then
            segment_pos=${segment_pos%% *} # copy text left from the first space
        fi
        if [[ $version_printed -eq 0 ]]; then
            PRINT_COMMANDS=$PRINT_COMMANDS$(echo "=== $segment_id ============================ v$VERSION\n")
            version_printed=1
        else
            PRINT_COMMANDS=$PRINT_COMMANDS$(echo "=== $segment_id =================================\n")
        fi
        local files=($(echo ${array["$segment_id"]} | tr ' ' "\n"))
        local count=1
        local total=${#files[@]}
        local partial_view=0
        local partial_view_from=$((total-2))
        if [[ $total -gt $LIST_TS_FILES_TOTAL ]]; then
            partial_view=1
        fi
        for file in ${files[@]}; do
            #
            # If there are more than 15 TS files then show first 12 files, ... and the last 2 TS files
            #
            if [[ $partial_view -eq 1 ]] && [[ $count -eq $LIST_TS_FILES_DOTS ]]; then
                line="..."
            else
                if [[ $partial_view -eq 1 ]]; then
                    if [[ $count -le $LIST_TS_FILES_DOTS ]] || [[ $count -ge $partial_view_from ]]; then
                        # go to print TS file
                        :
                    else
                        ((count++))
                        continue
                    fi
                else
                    # go to print TS file
                    :
                fi
                line=${file//•/ } # replace • with space
            fi
            #
            # print TS file
            #
            linelen=${#line}
            PRINT_COMMANDS=$PRINT_COMMANDS$(echo $line)
            local label=
            local info=
            case $count in
                1)
                label="POS:"
                info="$segment_pos"
                ;;
                2)
                label="PID:"
                if [ "$segment_pid" != "" ] && ps -p $segment_pid > /dev/null; then
                    info="$segment_pid"
                else
                    info="$segment_pid KILLED"
                fi
                ;;
                3)
                label="STATE:"
                info="$segment_state"
                ;;
            esac
            if [ "$info" != "" ]; then
                local infolen=${#info}
                [ $infolen -lt 11 ] && infolen=11
                local feeder=$((SCREEN_WIDTH-linelen-${#label}-$infolen)) # number of spaces to fill so that label and info is aligned at right edge
                PRINT_COMMANDS=$PRINT_COMMANDS$(printf %${feeder}s%s%11s "" "$label" "$info")
            fi
            PRINT_COMMANDS=$PRINT_COMMANDS$(echo "\n")
            ((count++))
        done
        #
        # TS count
        #
        local countfmt="COUNT: $((count - 1))"
        local countlen=${#countfmt}
        PRINT_COMMANDS=$PRINT_COMMANDS$(echo $countfmt)
        #
        # Performance
        #
        ts_id=${last_ts[$segment_id]}
        if [[ "${ts_perf[$segment_id]}" == "" ]]; then
            ts_perf[$segment_id]="$SECONDS $ts_id 0 0"
        else
            local prev_seconds=${ts_perf[$segment_id]%% *}
            local seconds_diff=$((SECONDS - prev_seconds))
            if [[ $seconds_diff -ge $COLLECT_TS_PERF_STATS_SECONDS ]]; then
                perf="${ts_perf[$segment_id]#* }" # skip $SECONDS
                local prev_ts_id="${perf%% *}" # retrieve $ts_id
                local ts_id_count=$((ts_id - prev_ts_id))
                if [[ $ts_id_count -gt 0 ]]; then # else if -eq 0 then will check performance every loop cycle until at least one TS file is created
                    ts_perf[$segment_id]="$SECONDS $ts_id $ts_id_count $seconds_diff"
                fi
            fi
        fi
        if [ "${ts_perf[$segment_id]}" != "" ]; then
            perf="${ts_perf[$segment_id]#* }" # remove $SECONDS
            perf="${perf#* }" # remove $ts_id
            ts_id_count="${perf%% *}" # retrieve $ts_id_count
            seconds_diff="${perf#* }" # retrieve $seconds_diff (last value)
            #
            if [[ "$seconds_diff" != "0" ]]; then
                PRINT_COMMANDS=$PRINT_COMMANDS$(printf %$((SCREEN_WIDTH - countlen))s "PERFORMANCE: $ts_id_count TS files created in $seconds_diff seconds")
            else
                local idx=${load_icon[$segment_id]}; [ "$idx" == "" ] && idx=0
                ((idx ++))
                case $idx in
                    1) icon_fmt="ᴖ" ;;
                    2) icon_fmt="ᴖ" ;;
                    3) icon_fmt="ᴖ" ;;
                    4) icon_fmt="ᴗ" ;;
                    5) icon_fmt="ᴗ" ;;
                    6) icon_fmt="ᴗ" ;;
                    7) icon_fmt="ᴑ" ;;
                    8) icon_fmt="ᴑ" ;;
                    9) icon_fmt="ᴑ" ;;
                   10) icon_fmt="ᴗ" ;;
                   11) icon_fmt="ᴗ" ;;
                    *) icon_fmt="ᴗ"; idx=0 ;;
                esac
                load_icon[$segment_id]="$idx"
                PRINT_COMMANDS=$PRINT_COMMANDS$(printf %$((SCREEN_WIDTH - countlen))s "PERFORMANCE: $icon_fmt loading...")
            fi
        fi
        #
        # End of COUNT & PERFORMANCE line
        #
        PRINT_COMMANDS=$PRINT_COMMANDS$(echo "\n")
    done
    IFS=$DEFAULT_IFS
}

while true; do
    PRINT_COMMANDS=$(clear -x)
    buf
    PRINT_COMMANDS=$PRINT_COMMANDS$(echo "----------------------------------------------------------------------\n")
    PRINT_COMMANDS=$PRINT_COMMANDS$(df $TRANSCODES_DIR -ha)
    #
    # Flicker free display implemented accord to https://unix.stackexchange.com/a/126153 and https://stackoverflow.com/a/66035054
    #
    echo -ne "$PRINT_COMMANDS"
    #sleep 0.1
done;
