#!bin/bash

#TRANSCODES_DIR=/config/transcodes
#SEMAPHORE_DIR=$FFMPEG_DIR/log #/config/log # use RAM drive for FFMPEG transcoding PID and PAUSE files

TRANSCODES_DIR=/config/transcodes
SEMAPHORE_DIR=/config/semaphore # use RAM drive for FFMPEG transcoding PID and PAUSE files

SECONDS=0 # reset timer
declare -A pause_seconds
TRANSCODES_DIR_ESCAPED=${TRANSCODES_DIR//\//\\\/} # convert "/config/transcodes" to "\/config\/transcodes"

function buf {
    DEFAULT_IFS=$IFS
    IFS=$'\n' # this will make FOR parsing each line instead of each whitespace
    declare -A buffs
    local buffered_id=
    local segment_id=
    for line in $(find $TRANSCODES_DIR -name "*.ts" -type f ! -size 0 -exec stat -c '%x %y %n' {} \; 2>/dev/null | sort -n -r); do
        local t=$line
        local ACC_DATE=${t%% *}; t=${t#* }
        local ACC_TIME=${t%% *}; t=${t#* }
        t=${t#* } # ignore +0000
        local MOD_DATE=${t%% *}; t=${t#* }
        local MOD_TIME=${t%% *}; t=${t#* }
        t=${t#* } # ignore +0000
        local FILESIZE=${t%% *}; t=${t#* }
        local FILENAME=${t%% *}

        [[ "$FILENAME" =~ $TRANSCODES_DIR_ESCAPED/(................................)([0-9]+).ts ]]
        segment_id=${BASH_REMATCH[1]}
        buffered_id=${BASH_REMATCH[2]}

        if [ "${buffs[$segment_id]}" == "" ]; then
            if [ "$ACC_DATE $ACC_TIME" \> "$MOD_DATE $MOD_TIME" ]; then
                buffs[$segment_id]=$buffered_id
            fi
        fi
    done

    declare -A array
    local line=

    for line in $(find $TRANSCODES_DIR -name "*.ts" -type f ! -size 0 -exec stat -c '%n %s %x %y' {} \; 2>/dev/null | sed 's/'$TRANSCODES_DIR_ESCAPED'\/\(................................\)\(.*\)/\2 \1/' | sort -t . -k 1 -g); do
        local ts_name=${line%% *}
        [[ "$ts_name" =~ ^([0-9]+).ts ]]
        local ts_id=${BASH_REMATCH[1]}
        [ "$ts_id" == "${buffs[$segment_id]}" ] && is_buffering="◄──.buffering" || is_buffering=
        segment_id=${line##* }
        array[$segment_id]="${array[$segment_id]} $ts_id..$is_buffering"
    done
    files=()
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
                segment_state="PAUSED $(($SECONDS-$sec))"
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
        echo "=== $segment_id =================================" # $segment_id will be 32 characters length
        local maxlen=70 # screen line width
        local files=($(echo ${array["$segment_id"]} | tr ' ' "\n"))
        local count=1
        for file in ${files[@]}; do
            line=${file//./ } # replace . with space
            linelen=${#line}
            printf $line
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
                    info="$segment_pid(KILLED)"
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
                local feeder=$((maxlen-linelen-${#label}-$infolen)) # number of spaces to fill so that label and info is aligned at right edge
                printf %${feeder}s%s%11s "" "$label" "$info" # label is left aligned, and info is right aligned left-padded with spaces at least 10 characters in length
            fi
            echo # line-feed
            ((count++))
        done
    done
    IFS=$DEFAULT_IFS
}

while true; do
    clear -x
    buf
    echo ----------------------------------------------------------------------
    df $TRANSCODES_DIR -ha
    sleep 0.7
done;