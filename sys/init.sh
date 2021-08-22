#!/bin/bash

SDEBUG=${SDEBUG-}
DEBUG=${SDEBUG-}
SCRIPTSDIR="$(dirname $(readlink -f "$0"))"
ODIR=$(pwd)
cd "$SCRIPTSDIR/.."
TOPDIR=$(pwd)

# now be in stop-on-error mode
set -e

# export back the gateway ip as a host if ip is available in container
if ( ip -4 route list match 0/0 &>/dev/null );then
    ip -4 route list match 0/0 \
        | awk '{print $3" host.docker.internal"}' >> /etc/hosts
    export DOCKER_HOST_IP=$(ip -4 route list match 0/0 \
        | awk '{print $3}')
fi

PYCHARM_DIRS="${PYCHARM_DIRS:-"/opt/pycharm /opt/.pycharm /opt/.pycharm_helpers"}"
OPYPATH="${PYTHONPATH-}"
for i in $PYCHARM_DIRS;do
    if [ -e "$i" ];then
        IMAGE_MODE="${FORCE_IMAGE_MODE-pycharm}"
        break
    fi
done

# load locales & default env
# load this first as it resets $PATH
for i in /etc/environment /etc/default/locale;do
    if [ -e $i ];then . $i;fi
done

# load virtualenv if any
for VENV in ./venv ../venv;do
    if [ -e $VENV ];then . $VENV/bin/activate;break;fi
done

PROJECT_DIR=$TOPDIR
if [ -e src ];then
    PROJECT_DIR=$TOPDIR/src
fi
# activate shell debug if SDEBUG is set
VERBOSE=
if [[ -n $SDEBUG ]];then set -x;VERBOSE="v";fi

DEFAULT_IMAGE_MODE=train
export IMAGE_MODE=${IMAGE_MODE:-${DEFAULT_IMAGE_MODE}}
IMAGE_MODES="(train)"
NO_START=${NO_START-}
MLTRAINER_CONF_PREFIX="${MLTRAINER_CONF_PREFIX:-"MLTRAINER__"}"
NO_IMAGE_SETUP="${NO_IMAGE_SETUP:-"1"}"
FORCE_IMAGE_SETUP="${FORCE_IMAGE_SETUP:-"1"}"
DO_IMAGE_SETUP_MODES="${DO_IMAGE_SETUP_MODES:-"train"}"
export PIP_SRC=${PIP_SRC:-/code/pipsrc}
NO_PIPENV_INSTALL=${NO_PIPENV_INSTALL-1}
PIPENV_INSTALL_ARGS="${PIPENV_INSTALL_ARGS-"--ignore-pipfile"}"

FINDPERMS_OWNERSHIP_DIRS_CANDIDATES="${FINDPERMS_OWNERSHIP_DIRS_CANDIDATES:-"$PIP_SRC data"}"
export APP_TYPE="${APP_TYPE:-mltrainer}"
export APP_USER="${APP_USER:-$APP_TYPE}"
export INIT_HOOKS_DIR="${INIT_HOOKS_DIR:-/code/sys/scripts/hooks}"
export APP_GROUP="$APP_USER"
export EXTRA_USER_DIRS="${EXTRA_USER_DIRS-}"
export USER_DIRS="${USER_DIRS:-". data /logs/cron ${EXTRA_USER_DIRS}"}"
SHELL_USER=${SHELL_USER:-${APP_USER}}

DOCKER_USERID="${DOCKER_USERID:-$(id -u $APP_USER)}"
if [ "x$DOCKER_USERID" = "x0" ];then
    RUN_USER=root
else
    RUN_USER=${APP_USER-}
fi

# mltrainer variables

# forward console integration
export TERM="${TERM-}" COLUMNS="${COLUMNS-}" LINES="${LINES-}"

debuglog() {
    if [[ -n "$DEBUG" ]];then echo "$@" >&2;fi
}

log() {
    echo "$@" >&2;
}

vv() {
    log "$@";"$@";
}

# Regenerate egg-info & be sure to have it in site-packages
regen_egg_info() {
    local f="$1"
    if [ -e "$f" ];then
        local e="$(dirname "$f")"
        if [[ -n $SDEBUG ]];then
            echo "Reinstalling egg-info in: $e" >&2
        fi
        if ! ( cd "$e" && gosu $APP_USER python setup.py egg_info >/dev/null 2>&1; );then
            ( cd "$e" && gosu $APP_USER python setup.py egg_info 2>&1; )
        fi
    fi
}

#  shell: Run interactive shell inside container
_shell() {
    local user="$APP_USER"
    if [[ -n $1 ]];then user=$1;shift;fi
    local bargs="${@:-bash}"
    local NO_VIRTUALENV=${NO_VIRTUALENV-}
    local NO_NVM=${NO_VIRTUALENV-}
    local VENV_NAME=${VENV_NAME:-venv}
    local USER_HOME="$(getent passwd $user| cut -d: -f6)"
    local VENV_PATHS=${VENV_PATHS:-./$VENV_NAME ../$VENV_NAME}
    local rc="$USER_HOME/.control_bash_rc"
    >"$rc" \
        echo "set -e$([[ -n ${SSDEBUG:-$SDEBUG} ]] && echo "x" )"
    if [[ -z "$NO_VIRTUALENV" ]];then
        for i in $VENV_PATHS;do
            if [ -e $i/bin/activate ];then
                >>"$rc" \
                    echo "deactivate 2>/dev/null||true&&. $i/bin/activate"
            fi
        done
    fi
    exec gosu $user bash -elc ". $rc && ${bargs}"
}

#  configure: generate configs from template at runtime
configure() {
    if [[ -n $NO_CONFIGURE ]];then return 0;fi
    if [ "x$(id -u $APP_USER)" != "x$DOCKER_USERID" ];then
        log "Changing userid to $DOCKER_USERID"
        vv usermod -o -u $DOCKER_USERID $APP_USER
    fi
    for i in $USER_DIRS;do
        if [ ! -e "$i" ];then mkdir -p "$i" >&2;fi
        chown $APP_USER:$APP_GROUP "$i"
    done
    if (find /etc/sudoers* -type f >/dev/null 2>&1);then chown -Rf root:root /etc/sudoers*;fi
    # regenerate any setup.py found as it can be an egg mounted from a docker volume
    # without having a chance to be built
    while read f;do regen_egg_info "$f";done < <( \
        find "$TOPDIR/setup.py" "$TOPDIR/src" "$TOPDIR/lib" \
        -maxdepth 2 -mindepth 0 -name setup.py -type f 2>/dev/null; )
    # copy only if not existing template configs from common deploy project
    # and only if we have that common deploy project inside the image
    if [ ! -e etc ];then mkdir etc;fi
    for i in sys/etc local/*deploy-common/etc local/*deploy-common/sys/etc;do
        if [ -d $i ];then cp -rfn${VERBOSE} $i/* etc >&2;fi
    done
    # install wtih frep any template file to / (eg: logrotate & cron file)
    for i in $(find etc -name "*.frep" -type f 2>/dev/null);do
        d="$(dirname "$i")/$(basename "$i" .frep)" \
            && di="/$(dirname $d)" \
            && if [ ! -e "$di" ];then mkdir -p${VERBOSE} "$di" >&2;fi \
            && echo "Generating with frep $i:/$d" >&2 \
            && frep "$i:/$d" --overwrite
    done
}

#  services_setup: when image run in daemon mode: pre start setup
#               like database migrations, etc
services_setup() {
    if [[ -z $NO_IMAGE_SETUP ]];then
        if [[ -n $FORCE_IMAGE_SETUP ]] || ( echo $IMAGE_MODE | egrep -q "$DO_IMAGE_SETUP_MODES" ) ;then
            : "continue services_setup"
        else
            log "No image setup"
            return 0
        fi
    else
        if [[ -n $SDEBUG ]];then
            log "Skip image setup"
            return 0
        fi
    fi
    # alpine linux has /etc/crontabs/ and ubuntu based vixie has /etc/cron.d/
    if [ -e /etc/cron.d ] && [ -e /etc/crontabs ];then cp -fv /etc/crontabs/* /etc/cron.d >&2;fi
}

fixperms() {
    if [[ -n $NO_FIXPERMS ]];then return 0;fi
    for i in $USER_DIRS;do
        if [ -e "$i" ];then
            chown $APP_USER:$APP_GROUP "$i"
        fi
    done
    while read f;do chown $APP_USER:$APP_GROUP "$f";done < \
        <(find $FINDPERMS_OWNERSHIP_DIRS_CANDIDATES \
          \( -type d -or -type f \) \
             -and -not \( -user $APP_USER -and -group $APP_GROUP \)  2>/dev/null|sort)
}

#  usage: print this help
usage() {
    drun="docker run --rm -it <img>"
    echo "EX:
$drun [ -e FORCE_IMAGE_SETUP] [-e IMAGE_MODE=\$mode]
    docker run <img>
        run either mltrainer, cron, or celery beat|worker daemon
        (IMAGE_MODE: $IMAGE_MODES)

$drun \$args: run commands with the context ignited inside the container
$drun [ -e FORCE_IMAGE_SETUP=1] [ -e NO_IMAGE_SETUP=1] [-e SHELL_USER=\$ANOTHERUSER] [-e IMAGE_MODE=\$mode] [\$command[ \args]]
    docker run <img> \$COMMAND \$ARGS -> run command
    docker run <img> shell -> interactive shell
(default user: $SHELL_USER)
(default mode: $IMAGE_MODE)

If FORCE_IMAGE_SETUP is set: run migrate/collect static
If NO_IMAGE_SETUP is set: migrate/collect static is skipped, no matter what
If NO_START is set: start an infinite loop doing nothing (for dummy containers in dev)
"
  exit 0
}

if ( echo $1 | egrep -q -- "--help|-h|help" );then
    usage
fi

if [[ -n ${NO_START-} ]];then
    while true;do echo "start skipped" >&2;sleep 65535;done
    exit $?
fi

execute_hooks() {
    local step="$1"
    local hdir="$INIT_HOOKS_DIR/${step}"
    if [ ! -d "$hdir" ];then return 0;fi
    shift
    while read f;do
        if ( echo "$f" | egrep -q "\.sh$" );then
            debuglog "running shell hook($step): $f"
            . "${f}"
        else
            debuglog "running executable hook($step): $f"
            "$f" "$@"
        fi
    done < <(find "$hdir" -type f -executable 2>/dev/null | egrep -iv readme | sort -V; )
}

# Run app
pre() {
    configure
    execute_hooks afterconfigure "$@"
    # fixperms may have to be done on first run
    if ! ( services_setup );then
        fixperms
        execute_hooks beforeservicessetup "$@"
        services_setup
    fi
    execute_hooks beforesefixperms "$@"
    fixperms
}

execute_hooks pre "$@"

# reinstall in develop any missing editable dep
if [ -e Pipfile ] && ( egrep -q  "editable\s*=\s*true" Pipfile ) && [[ -z "$(ls -1 ${PIP_SRC}/ | grep -vi readme)" ]] && [[ "$NO_PIPENV_INSTALL" != "1" ]];then
    pipenv install $PIPENV_INSTALL_ARGS 1>&2
fi

cmd=
if [[ "${1-}" = "shell" ]];then IMAGE_MODE=shell;shift;fi
cmd="$@"
if [[ -z "$cmd" ]];then
    if [[ $IMAGE_MODE = "shell" ]];then
        cmd=bash
    elif [[ $IMAGE_MODE = "train" ]];then
        cmd='log() { echo "$@">&2; } \
        && vv() { log "$@";"$@"; } \
        && for m in $MODEL_PATHS;do vv mlflow run --no-conda ${m};done'
    fi
fi
# only display startup logs when we start in daemon mode
# and try to hide most when starting an (eventually interactive) shell.
if ! ( echo "$NO_STARTUP_LOGS" | egrep -iq "^(no?)?$" );then pre 2>/dev/null;else pre;fi

execute_hooks post "$@"

if [[ $IMAGE_MODE = "pycharm" ]];then
    export VENV=$VENV
    cmdargs="$@"
    for i in ${PYCHARM_DIRS};do if [ -e "$i" ];then chown -Rf $APP_USER "$i";fi;done
    subshell="set -e"
    subshell="$subshell;if [ -e \$VENV ];then . \$VENV/bin/activate;fi"
    subshell="$subshell;cd $ODIR"
    subshell="$subshell;export PYTHONPATH=\"$OPYPATH:\${PYTHONPATH-}·\""
    subshell="$subshell;python $cmdargs"
    exec gosu $APP_USER bash -lc "$subshell"
fi

execute_hooks beforeshell "$@"
( cd $PROJECT_DIR && _shell $SHELL_USER "$cmd" )
