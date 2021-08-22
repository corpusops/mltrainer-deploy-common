#!/usr/bin/env bash
if [[ -n $DEBUG ]];then set -x;fi
set -e
readlinkf() {
    if ( uname | egrep -iq "darwin|bsd" );then
        if ( which greadlink 2>&1 >/dev/null );then
            greadlink -f "$@"
        elif ( which perl 2>&1 >/dev/null );then
            perl -MCwd -le 'print Cwd::abs_path shift' "$@"
        elif ( which python 2>&1 >/dev/null );then
            python -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$@"
        fi
    else
        val="$(readlink -f "$@")"
        if [[ -z "$val" ]];then
            val=$(readlink "$@")
        fi
        echo "$val"
    fi
}

NO_INIT=${NO_INIT-}
NO_SYNC=${NO_SYNC-}
NO_REGEN=${NO_REGEN-}
PY_VER=${PY_VER:-3.7}
NO_INSTALL=${NO_INSTALL-}
MLTRAINER_VER=${PY_VER:-2.2.4}
GDAL_VERSION="${GDAL_VERSION:-2.2.3}"

out=$PWD/test/testproject-$PY_VER-$MLTRAINER_VER
if [[ -n "$1" ]] && [ -e $1 ];then
    COOKIECUTTER="$1"
    shift
fi
u=${COOKIECUTTER-}


cd "$(dirname $(readlinkf $0 ))"/..


if [[ -z "$NO_INSTALL" ]];then
deactivate || /bin/true
if [ ! -e local/venv ];then
    virtualenv --python=python3 local/venv
fi
fi

. local/venv/bin/activate

if [[ -z $NO_INSTALL ]];then
pip install -U cookiecutter
fi


if [[ -z "$NO_REGEN" ]];then
rm -rf $out
if [[ -z "$u" ]];then
    u="$HOME/.cookiecutters/cookiecutter-mltrainer"
    if [ ! -e "$u" ];then
        u="https://github.com/corpusops/$(basename $u).git"
    else
        cd "$u"
        git fetch origin
        git pull --rebase
    fi
fi
cookiecutter --no-input -o "$out" -f "$u" \
    git_ns="ptest" \
    name="testproject" \
    py_ver="$PY_VER" \
    mltrainer_ver="$MLTRAINER_VER" \
    out_dir="." \
    tld_domain="mycorp.net" \
    use_submodule_for_deploy_code="y" \
    mltrainer_project_name="testproject" \
     "$@"
fi


if [[ -z $NO_SYNC ]];then
rsync -azv --delete ./ test/testproject/local/mltrainer-deploy-common/ --exclude=test/testproject --exclude=local --exclude=test
fi


cd $out

if [[ -z $NO_INIT ]];then
cp .env.dist .env
cp docker.env.dist docker.env
fi

if ! ( grep -iq gdal requirements.txt );then
    printf "GDAL==$GDAL_VERSION\n$(cat requirements.txt)" > requirements.txt
    echo libgdal-dev >> apt.txt
fi
./control.sh build mltrainer
# vim:set et sts=4 ts=4 tw=80:
