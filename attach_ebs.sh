#!/usr/bin/env sh
# attach_ebs.sh - Find, attach, partition, format, and mount an EBS volume
# Copyright (c) 2020-2021  Peter Willis
# 
# This script is designed to mount a single EBS volume based on its tag:Name
# in order to implement persistent storage. If there is more than one EBS volume
# with the same tag, this script will fail.

# shellcheck disable=SC1087,SC2034,SC2003,SC2004,SC2059

set -e -u

FS_OPTS="${FS_OPTS:-errors=remount-ro,nofail,noatime,nodiratime}"
FS_LABEL="${FS_LABEL:-data-vol}"
EBS_FIND_TIMEOUT="${EBS_FIND_TIMEOUT:-30}"
EBS_TAG_NAME="${EBS_TAG_NAME:-Name}"

################################################################################

ATTACH_EBS_VERSION="1.0"

_help () {
    [ $# -gt 0 ] && echo "$0: Error: $*"
    cat <<EOUSAGE
Usage: $0 [OPTIONS]
v$ATTACH_EBS_VERSION

Attempts to attach an EBS volume to an EC2 instance (by default, the current
EC2 instance). Can look for a particular EBS tag:Name, or a specific VOLUME_ID.

First waits for the volume to exist (up to '-T' time). Then waits for the volume
to be available to attach. Then attaches the volume. Then waits for the volume
to be attached.

Once the volume is attached:

  If FS_TYPE was passed: looks for filesystem type FS_TYPE on device 
  MOUNT_DEVICE. If the filesystem is not detected, and '-p' is specified, 
  creates a partition NAME (pass PARTED_SCRIPT or SFDISK_SCRIPT to customize
  partition creation). A filesystem is created on the resulting device.

  The DEVICE is mounted to DIRECTORY.
  If none already exists, an fstab entry is added for the mount.
  If a USER was passed, the newly mounted directory is 'chown'ed to that user.


Options:
    -i EC2_ID           The AWS EC2 instance ID (detected with EC2 metadata)
    -r REGION           The AWS region (detected with EC2 metadata)
    -V VOLUME_ID        Attach VOLUME_ID EBS volume instead of looking for the
                        volume with the '-t' option below
    -n NAME             Match an EBS volume with a tag named NAME (default: 'Name')
    -t VALUE            Match an EBS volume whose tag:NAME value is VALUE
    -T TIMEOUT          Seconds to try looking for an EBS volume with '-t'
    -d DEVICE           Mount EBS volume from DEVICE file
    -m DIRECTORY        Mount EBS volume on DIRECTORY
    -u USER             Make USER the owner of the newly-mounted DIRECTORY
    -F TYPE             The filesystem type to create if none exists
    -O OPTS             The filesystem mount options
    -L LABEL            The filesystem label name
    -p PART             Create partition name by concatenating DEVICE and PART
    -S                  Shutdown the host if the volume cannot be attached
    -h                  This help menu
    -v                  Turn on trace/debug mode

Environment variables:
    EC2_ID              Same as the '-i' EC2_ID
    AWS_REGION          Same as the '-r' REGION
    EBS_TAG_NAME        Same as the '-n' NAME
    EBS_TAG_VALUE       Same as the '-t' VALUE
    EBS_VOLUME_ID       Same as the '-V' VOLUME_ID
    EBS_FIND_TIMEOUT    Same as the '-T' TIMEOUT
    MOUNT_DEVICE        Same as the '-d' DEVICE
    MOUNT_DIR           Same as the '-m' DIRECTORY
    MOUNT_USER          Same as the '-u' USER
    PARTED_SCRIPT       A script to use to create a partition on the volume
    SFDISK_SCRIPT       A script to use to create a partition on the volume
    FS_TYPE             Same as the '-F' TYPE
    FS_OPTS             Same as the '-O' OPTS
    FS_LABEL            Same as the '-L' LABEL
    MK_PARTITION        Same as the '-p' PART
    SHUTDOWN            Same as the '-S' option
EOUSAGE
    exit 1
}

_shutdown () {
    echo "$0: Error: $1" 1>&2
    if [ "${SHUTDOWN:-1}" = "1" ] ; then
        echo "$0: Shutting down server in 1 minute." 1>&2
        /sbin/shutdown -h +1
    fi
    exit 1
}

_get_ebsid_tag () {
    # Try 30 times to get the EBS ID of the volume based on its tag:Name
    for i in $(seq 1 "$EBS_FIND_TIMEOUT") ; do
        # Command will output EBS volume ID on success
        if aws --region "$AWS_REGION" \
            ec2 describe-volumes \
            --filter "Name=tag:${EBS_TAG_NAME},Values=${EBS_TAG_NAME}" \
            --query "Volumes[0].{ID:VolumeId}" \
            --output text
        then
            return 0
        fi
        sleep 1
    done
}

# Get the state of an EBS ID
_ebs_state () {
    ebsid="$1"
    aws --region "$AWS_REGION" ec2 describe-volumes --filter "Name=volume-id,Values=$ebsid" --query "Volumes[0].{STATE:State}" --output text
}

# Wait for an EBS volume to no longer be attached or in-use, then attach it and wait
# for it to be in-use before proceeding.
_attach_ebs () {
    state ebsid
    count=0 tries=30 sleeptime=30

    EBS_VOLUME_ID="${EBS_VOLUME_ID:-$(_get_ebsid_tag)}"
    if [ -z "$EBS_VOLUME_ID" ] ; then
        _shutdown "Failed to find EBS volume by tag '${EBS_TAG_NAME:-}:${EBS_TAG_VALUE:-}' or id '${EBS_VOLUME_ID:-}' in $EBS_FIND_TIMEOUT seconds; shutting down"
    fi

    while [ $count -lt $tries ] ; do
        state="$(_ebs_state "$EBS_VOLUME_ID")"
        [ "$state" = "available" ] && break
        echo "$0: Volume $EBS_VOLUME_ID is in state '$state'; waiting for it to become available ..."
        sleep $sleeptime
        count=$(($count+1))
    done

    if [ $count -ge $tries ] ; then
        _shutdown "Volume ID '$EBS_VOLUME_ID' never became available; shutting down"
    fi

    if [ ! "$state" = "attached" ] && [ ! "$state" = "in-use" ] ; then
        aws ec2 --region "$AWS_REGION" attach-volume --volume-id "$EBS_VOLUME_ID" --instance-id "$EC2_ID" --device "$MOUNT_DEVICE"
    fi

    aws ec2 wait volume-in-use --region "$AWS_REGION" --volume-ids "$EBS_VOLUME_ID" \
        --filters "Name=attachment.instance-id,Values=$EC2_ID" "Name=attachment.status,Values=attached"
}

_has_fs () {
    if [ -n "${FS_TYPE:-}" ] ; then
        blkid "$MOUNT_DEVICE" | grep -i "$FS_TYPE"
    else
        return 0
    fi
}

_mk_part () {
    # Set MK_PARTITION to create and/or use a partition for the MOUNT_DEVICE
    if [ -z "${MK_PARTITION:-}" ] ; then
        return 0
    fi

    # If an initial partition doesn't exist, create one.
    PARTED_SCRIPT="${PARTED_SCRIPT:-mklabel gpt mkpart primary 0% 100%}"
    SFDISK_SCRIPT="${SFDISK_SCRIPT:-label: gpt\n;}"

    if ! blkid "$MOUNT_DEVICE" ; then
        # Where supported: GPT partition table and a single large initial partition
        if command -v parted >/dev/null ; then
            parted -a opt --script "$MOUNT_DEVICE" "$PARTED_SCRIPT"
        elif command -v sfdisk >/dev/null ; then
            printf "$SFDISK_SCRIPT\n" | sfdisk "$MOUNT_DEVICE"
        fi
    fi

    # wait up to 30 seconds for partition to show up.
    # default new partition: append "1" to $MOUNT_DEVICE
    for i in $(seq 1 30) ; do
        [ -b "${MOUNT_DEVICE}${MK_PARTITION}" ] && break
        sleep 1
    done
    if [ -b "${MOUNT_DEVICE}${MK_PARTITION}" ] ; then
        MOUNT_DEVICE="${MOUNT_DEVICE}${MK_PARTITION}"
    fi
}

_mk_fs () {
    if ! _has_fs ; then
        # Try to just mount it, just in case filesystem detection failed
        if ! mount -t "$FS_TYPE" -o "$FS_OPTS" "$MOUNT_DEVICE" "$MOUNT_DIR" ; then
            # Oh well, we gave it a shot. Format the partition.
            # Both 'ext4' and 'xfs' support a '-L' option for partition label, so might
            # as well tack that on
            "mkfs.$FS_TYPE" -L "$FS_LABEL" "$MOUNT_DEVICE"
        fi
    fi
}

_main () {

    EC2_ID="${EC2_ID:-$(curl --connect-timeout 4 -s http://169.254.169.254/latest/meta-data/instance-id)}"
    AWS_REGION="${AWS_REGION:-$(curl --connect-timeout 4 -s 169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/.$//')}"

    if ! _attach_ebs ; then
        _shutdown "Failed to attach EBS volume"
    fi

    # Prepend '/dev/' to MOUNT_DEVICE if missing
    if ! expr "$MOUNT_DEVICE" : /dev/ >/dev/null ; then
        MOUNT_DEVICE="/dev/$MOUNT_DEVICE"
    fi
    if [ ! -b "$MOUNT_DEVICE" ] ; then
        echo "$0: Error: failed to find block device '$MOUNT_DEVICE'"
        exit 1
    fi

    [ -d "$MOUNT_DIR" ] || mkdir -p "$MOUNT_DIR"

    # Create a filesystem if it doesn't exist yet (new volumes)
    if ! _has_fs ; then
        _mk_part
        _mk_fs
    fi

    if [ -n "${FS_TYPE:-}" ] ; then
        mount -t "$FS_TYPE" -o "$FS_OPTS" "$MOUNT_DEVICE" "$MOUNT_DIR"
        grep -q -e "[[:space:]]$MOUNT_DIR[[:space:]]" /etc/fstab || echo "$MOUNT_DEVICE  $MOUNT_DIR  $FS_TYPE  $FS_OPTS  1  2" >> /etc/fstab
    else
        mount -o "$FS_OPTS" "$MOUNT_DEVICE" "$MOUNT_DIR"
        grep -q -e "[[:space:]]$MOUNT_DIR[[:space:]]" /etc/fstab || echo "$MOUNT_DEVICE  $MOUNT_DIR  auto  $FS_OPTS  1  2" >> /etc/fstab
    fi

    [ -n "${MOUNT_USER:-}" ] && chown "${MOUNT_USER}" "$MOUNT_DIR"
}

################################################################################

SHOW_HELP=0
while getopts "t:n:T:m:d:u:V:i:r:F:O:L:p:Shv" args ; do
    case $args in
        t)  EBS_TAG_VALUE="$OPTARG" ;;
        n)  EBS_TAG_NAME="$OPTARG" ;;
        T)  EBS_FIND_TIMEOUT="$OPTARG" ;;
        m)  MOUNT_DIR="$OPTARG" ;;
        d)  MOUNT_DEVICE="$OPTARG" ;;
        u)  MOUNT_USER="$OPTARG" ;;
        V)  EBS_VOLUME_ID="$OPTARG" ;;
        i)  EC2_ID="$OPTARG" ;;
        r)  AWS_REGION="$OPTARG" ;;
        F)  FS_TYPE="$OPTARG" ;;
        O)  FS_OPTS="$OPTARG" ;;
        L)  FS_LABEL="$OPTARG" ;;
        p)  MK_PARTITION="$OPTARG" ;;
        S)  SHUTDOWN=1 ;;
        h)  SHOW_HELP=1 ;;
        v)  export DEBUG=1 ;;
        *)
            echo "$0: Error: unknown option $args" ;
            exit 1 ;;
    esac
done
shift $(($OPTIND-1))

[ $SHOW_HELP -eq 1 ] && _help
[ "${DEBUG:-0}" = "1" ] && set -x
if [ -z "${EBS_TAG_VALUE:-}" ] && [ -z "${EBS_VOLUME_ID:-}" ] ; then
    _help "you must supply either EBS_TAG_VALUE or EBS_VOLUME_ID"
fi
if [ -z "${MOUNT_DEVICE:-}" ] && [ -z "${MOUNT_DIR:-}" ] ; then
    _help "you must supply both MOUNT_DEVICE and MOUNT_DIR"
fi

_main
