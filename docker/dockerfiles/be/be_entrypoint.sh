#!/bin/bash

# Notes:
# There're several ENV variables used in the BE entrypoint script:
# * COREDUMP_ENABLED: when it's set to true and BE process is crashed, a coredump is generated and the BE process would be restarted;
# * DEBUG_MODE: when it's set to true, BE process is restarted always;

HOST_TYPE=${HOST_TYPE:-"IP"}
FE_QUERY_PORT=${FE_QUERY_PORT:-9030}
PROBE_TIMEOUT=60
PROBE_INTERVAL=2
HEARTBEAT_PORT=9050
MY_SELF=
MY_IP=`hostname -i`
MY_HOSTNAME=`hostname -f`
STARROCKS_ROOT=${STARROCKS_ROOT:-"/opt/starrocks"}
export STARROCKS_HOME=${STARROCKS_ROOT}/be
BE_CONFIG=$STARROCKS_HOME/conf/be.conf


log_stderr()
{
    echo "[`date`] $@" >&2
}

update_conf_from_configmap()
{
    if [[ "x$CONFIGMAP_MOUNT_PATH" == "x" ]] ; then
        log_stderr 'Empty $CONFIGMAP_MOUNT_PATH env var, skip it!'
        return 0
    fi
    if ! test -d $CONFIGMAP_MOUNT_PATH ; then
        log_stderr "$CONFIGMAP_MOUNT_PATH not exist or not a directory, ignore ..."
        return 0
    fi
    local tgtconfdir=$STARROCKS_HOME/conf
    for conffile in `ls $CONFIGMAP_MOUNT_PATH`
    do
        log_stderr "Process conf file $conffile ..."
        local tgt=$tgtconfdir/$conffile
        if test -e $tgt ; then
            # make a backup
            mv -f $tgt ${tgt}.bak
        fi
        ln -sfT $CONFIGMAP_MOUNT_PATH/$conffile $tgt
    done
}

show_backends(){
    timeout 15 mysql --connect-timeout 2 -h $svc -P $FE_QUERY_PORT -u root --skip-column-names --batch -e 'SHOW BACKENDS;'
}

parse_confval_from_cn_conf()
{
    # a naive script to grep given confkey from cn conf file
    # assume conf format: ^\s*<key>\s*=\s*<value>\s*$
    local confkey=$1
    local confvalue=`grep "\<$confkey\>" $BE_CONFIG | grep -v '^\s*#' | sed 's|^\s*'$confkey'\s*=\s*\(.*\)\s*$|\1|g'`
    echo "$confvalue"
}

collect_env_info()
{
    # heartbeat_port from conf file
    local heartbeat_port=`parse_confval_from_cn_conf "heartbeat_service_port"`
    if [[ "x$heartbeat_port" != "x" ]] ; then
        HEARTBEAT_PORT=$heartbeat_port
    fi

    if [[ "x$HOST_TYPE" == "xIP" ]] ; then
        MY_SELF=$MY_IP
    else
        MY_SELF=$MY_HOSTNAME
    fi

}

add_self()
{
    local svc=$1
    start=`date +%s`
    local timeout=$PROBE_TIMEOUT

    while true
    do
        log_stderr "Add myself ($MY_SELF:$HEARTBEAT_PORT) into FE ..."
        timeout 15 mysql --connect-timeout 2 -h $svc -P $FE_QUERY_PORT -u root --skip-column-names --batch -e "ALTER SYSTEM ADD BACKEND \"$MY_SELF:$HEARTBEAT_PORT\";"
        memlist=`show_backends $svc`
        if echo "$memlist" | grep -q -w "$MY_SELF" &>/dev/null ; then
            break;
        fi

        let "expire=start+timeout"
        now=`date +%s`
        if [[ $expire -le $now ]] ; then
            log_stderr "Time out, abort!"
            exit 1
        fi

        sleep $PROBE_INTERVAL

    done
}

svc_name=$1
if [[ "x$svc_name" == "x" ]] ; then
    echo "Need a required parameter!"
    echo "  Example: $0 <fe_service_name>"
    exit 1
fi

update_conf_from_configmap
collect_env_info
add_self $svc_name || exit $?
log_stderr "run start_be.sh"

if [[ "$COREDUMP_ENABLED" == "true" ]]; then
  # start inotifywait loop daemon to monitor core dump generation
  $STARROCKS_ROOT/upload_coredump.sh &
fi


addition_args=
if [[ "x$LOG_CONSOLE" == "x1" ]] ; then
    # env var `LOG_CONSOLE=1` can be added to enable logging to console
    addition_args="--logconsole"
fi

while true; do
  $STARROCKS_HOME/bin/start_be.sh $addition_args
  ret=$?
  if [[ $ret -ne 0 && "x$LOG_CONSOLE" != "x1" ]] ; then
      nol=50
      log_stderr "Last $nol lines of be.INFO ..."
      tail -n $nol $STARROCKS_HOME/log/be.INFO
      log_stderr "Last $nol lines of be.out ..."
      tail -n $nol $STARROCKS_HOME/log/be.out
  fi

  # Repeat launching BE process in the two scenarios:
  #  a. DEBUG_MODE is true;
  #  b. coredump is enabled, and the error code is SIGABRT(6) or SIGSEGV(11);
  # otherwise BE process should still exit.
  should_exit=true
  if [[ "$DEBUG_MODE" == "true" ]]; then
    should_exit=false
  fi

  if [[ "$COREDUMP_ENABLED" == "true" && ($ret -eq 134 || $ret -eq 139) ]]; then
    should_exit=false
  fi

  if [[ "$should_exit" == "true" ]]; then
    exit  $ret
  fi

  # Print a message indicating the failure
  log_stderr "starrocks_be process exited with status: $ret"
  echo "Restarting starrocks_be ..."

  # Wait for a few seconds before restarting
  sleep_interval=${BE_RESTART_WAIT_SECONDS:-5}
  echo "wait for $sleep_interval seconds ..."
  sleep $sleep_interval
done
