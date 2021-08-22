#!/usr/bin/env bash
log() { echo "$@" >&2; }
vv() { echo "$@" >&2; "$@"; }
is_server_mode() { echo "$@"|egrep -iq "serve ?.*$"; }
if [[ -n ${SDEBUG-} ]];then set -x;fi;
OWD="$(pwd)"
set -e
fixperms() {
    if [ "x${DOCKER_USERID}" = "x0" ];then return;fi
    if [ "x$(id -u $APP_USER)" != "x$DOCKER_USERID" ];then
        vv usermod -u $DOCKER_USERID $APP_USER
    fi
    while read f;do chown $APP_USER:$APP_GROUP "$f";done < \
        <(find $FINDPERMS_OWNERSHIP_DIRS_CANDIDATES \
          \( -type d -or -type f \) \
             -and -not \( -user $APP_USER \
             \) 2>/dev/null|sort)
}
MLFLOW_SKIP_EXPOSE_HOST=${MLFLOW_SKIP_EXPOSE_HOST-}
APP_VENV="${APP_VENV:-/$APP_USER-venv}"
APP_USERID="$(stat -c'%u' $APP_VENV)"
APP_USER="$(stat -c'%U' $APP_VENV)"
APP_GROUP="$APP_USER"
APP_HOME="$(getent passwd $APP_USER | cut -d: -f6 )"
TRACKING_SERVER_PORT=${TRACKING_SERVER_PORT:-5000}
DOCKER_USERID="${DOCKER_USERID:-$(id -u $APP_USER)}"
SDEBUG=${SDEBUG-}
FINDPERMS_OWNERSHIP_DIRS_CANDIDATES="/$APP_USER-venv $DATA_PATH"
export VENV=${VENV-"/$APP_USER-venv"}
export TRACKING_SERVER_PORT=${TRACKING_SERVER_PORT:-5000}
export MLFLOW_TRACKING_URI=${MLFLOW_TRACKING_URI:-"http://$DOCKER_HOST_IP:$TRACKING_SERVER_PORT"}
export BASH_ENV=$APP_HOME/.bashrc
export WORK_DIR=${WORK_DIR-}
export ARTIFACTS_ROOT="${ARTIFACTS_ROOT:-"s3://minio"}"
export MLFLOW_TRACKING_INSECURE_TLS=${MLFLOW_TRACKING_INSECURE_TLS-true}
if [ "x$DOCKER_USERID" = "x0" ];then
    RUN_USER=root
else
    RUN_USER=${APP_USER-}
fi
fixperms
cat > "/mlrun" << EBASH
#!/bin/bash
set -e
. /etc/bash.bashrc
. $VENV/bin/activate
$@
EBASH
chmod +x /mlrun
exec gosu $RUN_USER /mlrun
# vim:set et sts=4 ts=4 tw=80:
