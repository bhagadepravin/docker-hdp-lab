#!/bin/bash
########
# Author: Ratish Maruthiyodan
# Project: Docker HDP Lab
# Description: Script to start up the docker-hdp-cluster on every Docker Host
########

set -x

start() {

 if [ ! -f "/etc/docker-hdp-lab.conf" ]
 then
        echo -e "\nFile not Found: \"/etc/docer-hdp-lab.conf\"".
        echo -e "Copy the file \"docker-hdp-lab.conf\" to /etc/ and configure it, and run the setup script first\n"
        exit 1
 fi
 source /etc/docker-hdp-lab.conf

 # Disabling vm.swappiness
 echo 0 > /proc/sys/vm/swappiness

 # Disabling THP
 echo "never" > /sys/kernel/mm/transparent_hugepage/enabled
 echo "never" > /sys/kernel/mm/transparent_hugepage/defrag

 # Enabling ip_forward
 echo "1" > /proc/sys/net/ipv4/ip_forward

 if [ $SWARM_MANAGER == $HOSTNAME ]
 then
	docker ps -a | grep -q "consul"
	CONSUL_present=$?
	docker ps -a | grep -q "swarm_manager"
	SM_present=$?
	docker ps -a | grep -q "swarm_join"
	SJ_present=$?
	docker ps -a | grep -q "overlay-gatewaynode"
	OG_present=$?

	if [ "$CONSUL_present" -ne 0 ] || [ "$SM_present" -ne 0 ] || [ "$SJ_present" -ne 0 ] || [ "$OG_present" -ne 0 ]
	then
		echo "Execute the setup script before starting the Docker-HDP-Cluster"
		exit 1
	fi

	echo -e "\nStarting Consul Instance..."
	docker start consul
	sleep 20
	echo -e "\nStarting Swarm Manager Instance..."
	docker start swarm_manager
	sleep 10
	echo -e "\nStarting Swarm Join Instance..."
	docker start swarm_join
	echo -e "\nStarting Overlay Network Gateway Instance..."
	docker start overlay-gatewaynode
 fi

 if [ $LOCAL_REPO_NODE == $HOSTNAME ]
 then
	docker ps -a | grep -q "localrepo"
	LOCALREPO_present=$?
	if [ "$LOCALREPO_present" -ne 0 ]
	then
		echo "Execute the setup script on this node before starting the Docker-HDP-Cluster"
		exit 1
	fi
	docker start localrepo
 fi

docker ps | grep -q swarm_join
if [ $? -ne 0 ]
then
	echo -e "\nStarting Swarm Join Instance..."
	docker start swarm_join
fi

 route -n | grep -q $(echo $OVERLAY_NETWORK | awk -F "/" '{print $1}')
 if [ $? -ne 0 ]
 then
	echo "Adding Route Entry to reach Overlay network:: "
	if [ $SWARM_MANAGER == $HOSTNAME ]
	then
	    echo "route add -net $OVERLAY_NETWORK gw $(docker -H $SWARM_MANAGER:4000 exec overlay-gatewaynode hostname -i | awk '{print $2}')"
	    route add -net $OVERLAY_NETWORK gw $(docker -H $SWARM_MANAGER:4000 exec overlay-gatewaynode hostname -i | awk '{print $2}')
	else
	    echo "route add -net $OVERLAY_NETWORK gw $SWARM_MANAGER"
	    route add -net $OVERLAY_NETWORK gw $SWARM_MANAGER
	fi
 fi
 exit 0
}


stop() {
	docker kill $(docker ps -q)
	exit 0
}

case $1 in
  start|stop) "$1" ;;
esac
