#!/bin/sh

# adjusted to be used with dash/ash/busybox

# depends: cat, awk, modinfo, modprobe, mkswap, swapon, swapoff, mke2fs, mount, umount, chmod, chown


#=================
# return values:
#   0 ... OK
#   1 ... incorrect or empty ZRAM_CFG_FILE

#=================
# script configuration
ZRAM_CFG_FILE="/etc/zram-service.conf"

#=================
# script globals
ZRAM_CFG_COUNT=0

#=================
# check for shell type
case $(ls -l /bin/sh) in
  *busybox)
    SH_TYPE=ash
    NEWLINE=$'\n' # busybox ash shell syntax is same as bash
    ;;
  *dash)
    SH_TYPE=dash
    NEWLINE='\n'  # debian dash has different syntax
    ;;
  *bash)
    SH_TYPE=bash
    NEWLINE=$'\n' # bashism
    ;;
esac

# just to get rid of grep dependency, otherwise grep -E would do the trick
# $1 ... regex
# $2 ... filename (or nothing to read from stdin)
matches()
{
    awk "/$1/ {n++} END{ if (n==0) exit 1}" $2
    return $?
}


# parse zram.cfg file into ZRAM_CFG array
read_zram_cfg()
{
    if [ $ZRAM_CFG_COUNT -gt 0 ] ; then
        return 0
    fi
    # note: using awk is more straight forward, though it is one more dependency
    # note: using sed and iterating over lines does not work in dash
    eval $(awk '!/^($|[ ]*#)/ {++i; print "ZRAM_CFG_"i"=\""$0"\";"} END {print "ZRAM_CFG_COUNT="i";"}' "$ZRAM_CFG_FILE")
    if [ $ZRAM_CFG_COUNT -eq 0 ] ; then 
        echo "Nothing configured in $ZRAM_CFG_FILE"
        return 1
    fi
}

zram_start()
{
    read_zram_cfg || return 1

    local modprobe_args
    if modinfo zram | matches ' zram_num_devices:' > /dev/null ; then
        modprobe_args="zram_num_devices=${ZRAM_CFG_COUNT}"
    elif modinfo zram | matches ' num_devices:' > /dev/null ; then
        modprobe_args="num_devices=${ZRAM_CFG_COUNT}"
    fi

    if [ -n "$modprobe_args" ] ; then
        modprobe zram $modprobe_args
    else
        echo "zram module cannot be loaded"
        return 2
    fi

    # wait up to 10 secs for devices to became available
    local i=0
    while [ $i -lt 10 ] ; do
        if [ -e /dev/zram0 ] ; then
            break
        fi
	sleep 1
	: $((i=i+1))
    done

    # mount filesystem or swap
    local line
    i=0
    while [ $i -lt $ZRAM_CFG_COUNT ] ; do
        local dev="zram$i"
        : $((i=i+1))
        eval "line=\"\$ZRAM_CFG_$i\""
        echo "$dev is $line"
        local disksize=$(cat /sys/block/$dev/disksize)
        if [ $disksize -ne 0 ] ; then
            continue
        fi
        set $line # no quotes! # mountpoint size <mode> <owner>
        local mountpoint=$1
        local size=$2
        local mode=${3:-1777}
        local owner=$4
        if matches lz4 /sys/block/$dev/comp_algorithm > /dev/null ; then # use lz4 algorithm if possible
            echo lz4 > /sys/block/$dev/comp_algorithm
        fi
        if echo "$size" | matches '[0-9]+[KMG]?' > /dev/null ; then
            if [ $mountpoint = swap ] ; then
                echo $size > /sys/block/$dev/disksize
                mkswap /dev/$dev
                swapon -p 32767 /dev/$dev
	    else
		if [ ! -d $mountpoint ] ; then
		    if ! mkdir -p $mountpoint ; then
			echo "$dev: cannot create $mountpoint and it does not exist"
		    fi
		fi
		if [ -d $mountpoint ] ; then
                    echo $size > /sys/block/$dev/disksize
                    mke2fs -t ext4 -O ^has_journal,^huge_file,sparse_super,extent,^uninit_bg,dir_nlink,extra_isize /dev/$dev
                    tune2fs -c0 -m0 -i0 /dev/$dev
                    mount -o noatime,norelatime,nostrictatime,nodiratime,noiversion,nodev,nosuid /dev/$dev $mountpoint
                    chmod $mode $mountpoint
                    if [ -n "$owner" ] ; then
			chown $owner $mountpoint
                    fi
		fi
            fi
        fi
    done
}

zram_stop()
{
  # disk
    # ignore configuration file, parse /proc/mounts instead
    local line
    #sed -n -e 's@^/dev/\(zram[^ ]*\).*$@\1@p' /proc/mounts |
    awk '/^\/dev\/zram/ {print substr($1,6)}' /proc/mounts |
        while read dev; do
            umount -l -f /dev/$dev
            echo 1 > /sys/block/$dev/reset
        done

    # swap
    # ignore configuration file, parse /proc/swaps instead
    local dev
    #sed -n -e 's@^/dev/\(zram[^ ]*\).*$@\1@p' /proc/swaps | 
    awk '/^\/dev\/zram/ {print substr($1,6)}' /proc/swaps |
        while read dev; do
            swapoff /dev/$dev
            echo 1 > /sys/block/$dev/reset
        done

    # remove module, so that new configuration could have effect (e.g. different number of zrams)
    rmmod zram
}

zram_status()
{
    #read_zram_cfg
    if [ ! -e /sys/block/zram0 ] ; then
        echo 'zram not initialized'
        return
    fi
    # read mount points
    #eval $(sed -n -e 's@^/dev/\(zram[^ ]*\)[ ]*\([^ ]*\).*$@local \1="\2";@p' /proc/mounts)
    eval $(awk '/^\/dev\/zram/ {print "local " substr($1,6) "=\"" $2 "\";" ;}' /proc/mounts)
    # read swaps
    #eval $(sed -n -e 's@^/dev/\(zram[^ ]*\).*$@local \1=swap;@p' /proc/swaps)
    eval $(awk '/^\/dev\/zram/ {print "local " substr($1,6) "=swap;" ;}' /proc/swaps)

    echo "      algo          disk    size    orig   compr  memory mountpoint"
    cd /sys/block
    local dev
    for dev in zram* ; do
        eval "local mountpoint=\$$dev"
        local algo="$(cat $dev/comp_algorithm)"
        local comp_size=$(cat $dev/compr_data_size)
        local disksize=$(cat $dev/disksize)
        local mem_total=$(cat $dev/mem_used_total)
        local orig_size=$(cat $dev/orig_data_size)
        local size=$(cat $dev/size)
        printf "%s %-10s %6dK %6dK %6dK %6dK %6dK %s\n" \
            $dev "$algo" \
            $((disksize/1024)) $((size/1024)) $((orig_size/1024)) $((comp_size/1024)) $((mem_total/1024)) \
            $mountpoint
    done
    cd - > /dev/null
}

test_config()
{
    read_zram_cfg
    echo "zram configuration: $ZRAM_CFG_COUNT lines:"
    i=0
    while [ $i -lt $ZRAM_CFG_COUNT ] ; do
        dev="zram$i"
        : $((i=i+1))
        eval "line=\"\$ZRAM_CFG_$i\""
        echo "$dev is $line"
        set $line # no quotes! # mountpoint size <mode> <owner>
        if [ $1 = swap ] ; then
            :
        elif [ -d $1 ] ; then
            :
        else
            echo "  $1 does not exist"
        fi
      done
}

# main
case $1 in
    start)
        zram_start || exit $?
        ;;
    stop)
        zram_stop || exit $?
        ;;
    status)
        zram_status
        ;;
    "test-config")
        test_config
      ;;
esac
