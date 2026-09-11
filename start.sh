#!/bin/bash

rm -f pull.log

set -ex

#I need to point to the right api server based on the environment we are in
host=brainlife.io

group_id=$(jq -r .group config.json)
container=$(jq -r .container config.json)

#deprecated
app=$(jq -r .app config.json)

#path to staged notebook content
notebook=$(jq -r .notebook config.json)

project_id=$(jq -r .project._id config.json)

#validate container name
case "$container" in
jupyter/*)
    echo "accepted.. jupyter container"
    ;;
brainlife/*)
    echo "accepted.. brainlife container"
    ;;
*)
    echo "invalid container"
    exit 1
esac

echo "finding open port"
port=$(./find_open_port.py)

base_url="/${URL_PREFIX:-ipython}/$port/"

token=$(openssl rand -hex 32)

cat <<EOF > jupyter_notebook_config.py
from jupyter_core.paths import jupyter_data_dir

c = get_config()
c.NotebookApp.base_url = '$base_url'
c.NotebookApp.ip = '0.0.0.0'
c.NotebookApp.port = 8080
c.NotebookApp.open_browser = False
c.NotebookApp.token = '$token'
c.NotebookApp.notebook_dir = '/notebook'

# https://github.com/jupyter/notebook/issues/3130
#c.FileContentsManager.delete_to_trash = False

c.NotebookApp.tornado_settings = {
  'headers': {
        #'Access-Control-Allow-Origin': "*",
        #'Access-Control-Allow-Credentials': "true",
        #'Access-Control-Allow-Methods': "OPTIONS",
        'Content-Security-Policy': "frame-ancestors 'self' http://localhost:8080 https://dev1.soichi.us https://brainlife.io https://test.brainlife.io https://lite.brainlife.io"
  }
}

# TODO - we need to secure by generated token for each jupyterhub instance, but also with token from brainlife jwt as specific user
# The secrect key used to generate the given token
#c.JSONWebTokenAuthenticator.secret = '$JWT_PUBLIC_KEY'
#c.JSONWebTokenAuthenticator.username_claim_field = 'sub'
#c.JSONWebTokenAuthenticator.expected_audience = '$JWT_ISSUER'
#
# This will enable local user creation upon authentication, requires JSONWebTokenLocalAuthenticator
##c.JSONWebLocalTokenAuthenticator.create_system_users = True                       
EOF

#TODO - what if user really wants to reinstall the notebook?
if [ ! -d notebook ]; then

  #deprecated
  if [ "$app" != "null" ]; then
      echo "git cloning requested app"
      git clone https://github.com/$app.git notebook
  fi
  #chown -R $UID:1000 notebook #make it accessible by jovyan

  if [ "$notebook" != "null" ]; then
    echo "copying staged notebook so we can update it"
    #install -d $notebook notebook #doesn't work anymore?
    cp -r $notebook notebook
  fi

  #the internal user jovyan(1000) needs to have access to notebook directory created here
  #maybe I should do this internally so ID will match? 
  #or maybe use docker image container?
  chmod -R 777 notebook 

  #inject config.json to notebook incase user needs it
  cp config.json notebook
fi

#chmod 777 home #I think we do this so jovyan user can access it?
#cp .bashrc home/

input_mount=""
if [ -d /mnt/secondary/$group_id ]; then
    input_mount="-v /mnt/secondary/$group_id:/input:ro,shared -v /mnt/secondary/$group_id:/notebook/input:ro,shared"
fi

#pull s3fs mount metadata from amaretti /task/:id/bootstrap and mount on host, then
#bind-mount into the container (same pattern as input_mount above; the jupyter container
#is unprivileged so it can't run s3fs itself). Mirrors mount_task_s3() in docker/runner/bootstrap.sh.
#s3 mounts are best-effort - a failure here must not stop the notebook from launching
s3_mount=""
if [ -n "$BRAINLIFE_API_URL" ] && [ -n "$BRAINLIFE_API_JWT" ] && [ -n "$TASK_ID" ]; then
    set +e
    export AWS_REGION="${AWS_REGION:-us-east-2}"
    mounts=$(curl -fsS -H "Authorization: Bearer $BRAINLIFE_API_JWT" "$BRAINLIFE_API_URL/task/$TASK_ID/bootstrap")
    if [ $? -ne 0 ]; then
        echo "failed to fetch bootstrap metadata - continuing without s3 mounts"
        mounts='{"mounts":[]}'
    fi
    while read -r m; do
        type=$(echo "$m" | jq -r '.type // "s3"')
        mountpoint=$(echo "$m" | jq -r .mountpoint)
        readonly=$(echo "$m" | jq -r .readonly)
        mkdir -p "$mountpoint"

        if [ "$type" = "dandi" ]; then
            #dandifs.py maps the DANDI API onto a folder tree; no AWS creds needed
            dandiset=$(echo "$m" | jq -r .dandiset)
            version=$(echo "$m" | jq -r '.version // "draft"')
            if ! mountpoint -q "$mountpoint"; then
                DANDIFS_ALLOW_OTHER=1 nohup python3 "$(pwd)/dandifs.py" "$mountpoint" "$dandiset" "$version" > "dandi.$dandiset.log" 2>&1 &
                for i in $(seq 1 10); do mountpoint -q "$mountpoint" && break; sleep 0.5; done
            fi
        else
            bucket=$(echo "$m" | jq -r .bucket)
            prefix=$(echo "$m" | jq -r .prefix)
            opts="-o allow_other -o use_path_request_style -o url=https://s3.$AWS_REGION.amazonaws.com -o endpoint=$AWS_REGION -o public_bucket=1"
            [ "$readonly" = "true" ] && opts="$opts -o ro"
            mountpoint -q "$mountpoint" || s3fs "$bucket:/$prefix" "$mountpoint" $opts
        fi

        if ! mountpoint -q "$mountpoint"; then
            echo "failed to mount $mountpoint ($type) - skipping"
            continue
        fi

        bind="rw"; [ "$readonly" = "true" ] && bind="ro"
        s3_mount="$s3_mount -v $mountpoint:$mountpoint:$bind,shared"
    done < <(echo "$mounts" | jq -c '.mounts[]')
    set -e
fi

#mount DANDI datasets as a folder tree on the host, then bind-mount into the container -
#same pattern as s3_mount above (the unprivileged container can't run FUSE itself).
#dandifs.py talks to the DANDI API and streams file bytes from public S3 blobs.
#set "dandiset" in config.json to a dandiset id (e.g. "000003") or "all" for the whole archive.
#best-effort - a failure here must not stop the notebook from launching
dandi_mount=""
dandiset=$(jq -r '.dandiset // empty' config.json)
if [ -n "$dandiset" ]; then
    set +e
    dandi_mp="/mnt/dandi/$TASK_ID"
    mkdir -p "$dandi_mp"
    dandi_args="$dandi_mp"
    [ "$dandiset" != "all" ] && dandi_args="$dandi_args $dandiset"
    if ! mountpoint -q "$dandi_mp"; then
        DANDIFS_ALLOW_OTHER=1 nohup python3 "$(pwd)/dandifs.py" $dandi_args > dandi.log 2>&1 &
        for i in $(seq 1 10); do mountpoint -q "$dandi_mp" && break; sleep 0.5; done
    fi
    if mountpoint -q "$dandi_mp"; then
        dandi_mount="-v $dandi_mp:/notebook/dandi:ro,shared"
    else
        echo "failed to mount DANDI - skipping"
    fi
    set -e
fi

#for ui
cat <<EOF > container.json
{
    "port": $port,
    "token": "$token",
    "prefix": "$URL_PREFIX"
}
EOF

[ -z $TASK_ID ] && TASK_ID="debug"

name=$group_id.$TASK_ID
docker rm -f $name || true

echo "starting container - might take a while for the first time"
nohup docker run \
    --name $name \
    --restart=always \
    -v `pwd`/notebook:/notebook \
    -v `pwd`/jupyter_notebook_config.py:/etc/jupyter/jupyter_notebook_config.py \
    -e PROJECT_ID=$project_id \
    $input_mount \
    $s3_mount \
    $dandi_mount \
    -p $port:8080 \
    --memory=16g \
    --cpus=4 \
    -d $container > container.id 2> pull.log &


