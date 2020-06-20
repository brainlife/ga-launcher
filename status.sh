#!/bin/bash

#return code 0 = running
#return code 1 = finished successfully
#return code 2 = failed
#return code 3 = unknown (retry later)

if [ ! -s container.id ]; then
    if [ -f pull.log ]; then
	    tail -1 pull.log
	    exit 0
    else
	    echo "container fail to start?"
	    exit 3
    fi
fi

id=$(cat container.id)
docker inspect $id > inspect.json
if [ $? -eq 0 ]; then

    #wait for the port to start
    port=$(jq .port container.json)
    curl -sf http://localhost:$port
    if [ $? -eq 7 ]; then
        echo "waiting for port to open"
        exit 0
    fi

    echo "running"
    exit 0 #running
else
    echo "not running"
    exit 2 #disappeared?
fi


