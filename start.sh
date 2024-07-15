#!/bin/bash

rm -f pull.log

set -e

#I need to point to the right api server based on the environment we are in
host=brainlife.io
[ $HOSTNAME == "dev1.soichi.us" ] && host=dev1.soichi.us
[ $HOSTNAME == "ga-test" ] && host=test.brainlife.io

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

token=$(openssl rand -hex 32)

cat <<EOF > jupyter_notebook_config.py
from jupyter_core.paths import jupyter_data_dir

c = get_config()
c.NotebookApp.base_url = '/ipython/$port/'
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

#for ui
cat <<EOF > container.json
{
    "port": $port,
    "token": "$token"
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
    -p $port:8080 \
    --memory=16g \
    --cpus=4 \
    -d $container > container.id 2> pull.log &


