#!/usr/bin/env bash
set -e
taropts=cJf
verbose=
if [[ -n ${DEBUG-} ]];then
    set -x
    verbose=v
fi
ROOT_DIR=${ROOT_DIR:-/code}
DATAS_DIR="${DATAS_DIR:-$ROOT_DIR/data}"
KEEP_ARCHIVES="${KEEP_ARCHIVES:-6}"
KEEP_ARCHIVESINC="$(($KEEP_ARCHIVES - 1))"
ARCHIVES_DIR="${ARCHIVES_DIR:-${DATAS_DIR}/nobackup/archives}"
ARCHIVE_PATH="${ARCHIVE_PATH:-${ARCHIVES_DIR}/last.tar.xz}"
DUMP_PATH="${DUMP_PATH:-${DATAS_DIR}/nobackup/dumps}"
PG_DUMP_OPTS="${PG_DUMP_OPTS:-"-Fc"}"
NO_DUMP=${NO_DUMP-}
NO_ARCHIVE=${NO_ARCHIVE-}
NO_ARCHIVE_TAR=${NO_ARCHIVE_TAR-}
NO_MEDIA=${NO_MEDIA-}
NO_STATIC=${NO_STATIC-1}
MEDIA_DIR=${MEDIA_DIR:-public/media}
STATICS_DIR=${STATICS_DIR:-public/static}

cd "$ROOT_DIR"
for d in "$DUMP_PATH" "$ARCHIVES_DIR";do
    if [ ! -e "$d" ];then mkdir -p "$d";fi
done
exclude="$exclude $(cd /code && \
    find "$(pwd)" \
    -wholename '*/data/nobackup/archives' -or \
    -name '*venv' \
    | sed -re "s/^(.*)$/--exclude=\1/g" )"

if [[ -n $NO_MEDIA ]];then exclude="$exclude --exclude=$(pwd)/$MEDIA_DIR";fi
if [[ -n $NO_STATIC ]];then exclude="$exclude --exclude=$(pwd)/$STATICS_DIR";fi


if [[ -z $NO_DUMP ]];then
    PGPASSWORD="$POSTGRES_PASSWORD" pg_dump \
        -f "$DUMP_PATH/last.sql" \
        --host="$POSTGRES_HOST" --port="$POSTGRES_PORT" --user="$POSTGRES_USER" \
        $PG_DUMP_OPTS \
        $POSTGRES_DB
fi

if [[ -z ${NO_ARCHIVE} ]];then
    if [[ -z $NO_ROTATE ]];then
        if [[ $KEEP_ARCHIVES -gt 1 ]];then
            for i in $(seq 1 $KEEP_ARCHIVES|sort -r);do
                la=${ARCHIVE_PATH}.${i}
                nla=${ARCHIVE_PATH}.$((${i}+1))
                if [ -e "$la" ];then
                    mv -${verbose}f "$la" "$nla"
                fi
            done
        fi
        if [ -e "${ARCHIVE_PATH}" ];then
            mv -f${verbose} "${ARCHIVE_PATH}" "$ARCHIVE_PATH.1"
        fi
        if ( ls $ARCHIVE_PATH.* &> /dev/null);then
            rm -f${verbose} $(ls -1 $ARCHIVE_PATH.* | sort -V | awk "NR > $KEEP_ARCHIVES")
        fi
    fi
    if [[ -z ${NO_ARCHIVE_TAR} ]];then
        cd "$ROOT_DIR" \
            && tar $exclude -cJ${verbose}f ${ARCHIVE_PATH} $ROOT_DIR
    fi
fi
# vim:set et sts=4 ts=4 tw=80:
