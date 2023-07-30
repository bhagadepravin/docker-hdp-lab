#!/bin/bash
########
# Author: Pravin Bhagade
# Project: Docker ODP Lab
# Description: Docker Lab Installation Script for Centos 7
########

set -x
set -e

if [ ! -f "/etc/docker-hdp-lab.conf" ]
then
      echo -e "\n\tFile not Found: [ /etc/docker-hdp-lab.conf ] \nCopy the File: \"docker-hdp-lab.conf\" to /etc and Configure it Before Running ./install\n"
      exit 1
fi

source /etc/docker-hdp-lab.conf

SWARM_MANAGER_IP=$(getent ahosts $SWARM_MANAGER | head -n 1 | awk '{print $1}')
if [ -z $SWARM_MANAGER_IP ]
then
      echo -e "\nCheck the value set for SWARM_MANAGER host in the config file /etc/docker-hdp-lab.conf"
      echo -e "Its Either Incorrect Or the Hostname [ $SWARM_MANAGER ] Cannot be Resolved..\n"
      exit 1
fi

CONSUL_MANAGER=$SWARM_MANAGER_IP

echo -e "\nContinuing the install will overwrite the existing files, if the Docker-hdp-lab was already setup on this host"
read -p "Do you still want to continue ? [Y/N] : " choice
if [ "$choice" != "Y" ] && [ "$choice" != "y" ]
then
      exit 1
fi

if [ -z $LOCAL_IP ]
then
      LOCAL_IP=$(getent ahosts $HOSTNAME | head -n 1 | awk '{print $1}')
      echo "Choosing the IP $LOCAL_IP for the consul and Docker Host."
      read -p "Do you want to Change it by editing /etc/docker-hdp-lab.conf ? [Y/N] : " choice
      if [ "$choice" == "Y" ] || [ "$choice" == "y" ]
      then
            exit 1
      fi
fi

echo "echo \"never\" > /sys/kernel/mm/transparent_hugepage/enabled" >> /etc/rc.local
echo "echo \"never\" > /sys/kernel/mm/transparent_hugepage/defrag" >> /etc/rc.local
echo 0 > /proc/sys/vm/swappiness

echo -e "\n\tChecking if the user already has RSA keys for SSH & Creating if not...\n"
if [ ! -e /root/.ssh/id_rsa ] || [  ! -e /root/.ssh/id_rsa.pub ]
then
      ssh-keygen
fi

rm -f  ambari-agent-template/id_rsa*
rm -f ambari-server-template/id_rsa*
cp  /root/.ssh/id_rsa* ambari-agent-template/
cp  /root/.ssh/id_rsa* ambari-server-template/

yum install -y nc wget net-tools bc
yum update -y

echo -e "\nPlease Restart the node if there were kernel updates applied. Some of the features require later versions of kernel"
read -p "Press 'Y' to Exit the Install & manually reboot the node Or 'N' to continue with install [Y/N] : " choice
if [ "$choice" == "Y" ] || [ "$choice" == "y" ]
then
      echo -e "\n\tAfter Restarting the System, please run ./install again\n"
        exit 0
fi


echo "Deleting existing directories if exists at /opt/docker_cluster/ambari-agent-template and /opt/docker_cluster/ambari-server-template"
set +e
rm -rf /opt/docker_cluster/ambari-agent-template
rm -rf /opt/docker_cluster/ambari-server-template
set -e

if [ ! -d "/opt/docker_cluster" ]
then
      mkdir /opt/docker_cluster
fi
cp  -r ambari-agent-template /opt/docker_cluster
cp  -r ambari-server-template /opt/docker_cluster



set +e
systemctl stop NetworkManager
systemctl disable NetworkManager.service

service firewalld stop
systemctl disable firewalld.service
set -e

echo "1" > /proc/sys/net/ipv4/ip_forward

echo -e "\n\tSetting up Docker Yum Repo and Installing Docker Engine\n"

    echo "Installing Docker..."
    sudo yum update -y
    sudo yum install -y yum-utils device-mapper-persistent-data lvm2
    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    sudo yum install -y docker-ce
    sudo systemctl start docker
    echo "Docker installed successfully."

sleep 5
if [ $SWARM_MANAGER == $HOSTNAME ] || [ $SWARM_MANAGER == `hostname -s` ] || [ $SWARM_MANAGER == `hostname -f` ]
then
      echo -e "\n\tStarting Consul instance (takes a few seconds to start)\n"
      docker run -d -p 8500:8500 --name=consul progrium/consul -server -bootstrap

      sleep 20
      echo -e "\n\tStarting swarm manager and then 15s sleep\n"
      docker run -d -p 4000:4000 --name=swarm_manager swarm manage -H :4000 --replication --advertise $LOCAL_IP:4000 consul://$CONSUL_MANAGER:8500

      sleep 15
      echo -e "\n\tStarting Swarm join and 10s sleep\n"
      docker run --name=swarm_join  -d swarm join --advertise=$LOCAL_IP:2375 consul://$CONSUL_MANAGER:8500

      sleep 10
      echo -e "\n \tCreating Overlay network...\n"
      #docker -H $SWARM_MANAGER_IP:4000 network create --driver overlay --subnet=$OVERLAY_NETWORK $DEFAULT_DOMAIN_NAME
      docker network create --driver overlay --attachable --subnet=$OVERLAY_NETWORK $DEFAULT_DOMAIN_NAME
      
      if [ $? -ne 0 ]
      then
         echo -e "\nCheck whether the consul instance is running and port 8500 is reachable. May be the host firewall is running\n"
      fi
      if [ ! -d "/tmp/gateway-instance" ]
      then
            mkdir /tmp/gateway-instance
      fi
      
      echo -e "\n\t Creating Overlay Network Gateway Instance \n"
      cat > /tmp/gateway-instance/start << EOF
#!/bin/bash
service sshd restart
service dnsmasq restart
/usr/sbin/sshd -d -p 2222
EOF
      chmod +x  /tmp/gateway-instance/start
      cat > /tmp/gateway-instance/Dockerfile << EOF
FROM centos:7
RUN yum update -y && yum install -y iproute
RUN yum install -y openssh-server openssh-clients dnsmasq nettle
RUN echo "root:hadoop" | chpasswd
RUN systemctl enable sshd
RUN ssh-keygen -A
RUN mkdir -p /root/.ssh && touch /root/.ssh/authorized_keys && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys
ADD ./start /
CMD ["/start"]
EOF
      echo -e "\n\t Building images for Overlay network gateway...\n"
      docker build -t gatewaynode /tmp/gateway-instance/
      sleep 5
      docker run -d --hostname overlay-gatewaynode --name overlay-gatewaynode  --net $DEFAULT_DOMAIN_NAME --net-alias=overlay-gatewaynode  --privileged gatewaynode
      OVERLAY_GATEWAY_IP=$(docker exec overlay-gatewaynode hostname -i)
      echo -e "\n\t Adding Route to reach the Overlay Network :: route add -net $OVERLAY_NETWORK gw $OVERLAY_GATEWAY_IP\n"
      set +e
      route delete -net $OVERLAY_NETWORK 
      route add -net $OVERLAY_NETWORK gw $OVERLAY_GATEWAY_IP
      set -e
else
        docker run -d  --name=swarm_join swarm join --advertise=$LOCAL_IP:2375 consul://$CONSUL_MANAGER:8500
      if [ $(route -n | grep -q $(echo $OVERLAY_NETWORK | awk -F "/" '{print $1}')) ]
       then
          route add -net $OVERLAY_NETWORK gw $SWARM_MANAGER_IP
       fi

fi

if [ $LOCAL_REPO_NODE == $HOSTNAME  ] ||  [ $LOCAL_REPO_NODE == `hostname -s`  ] ||  [ $LOCAL_REPO_NODE == `hostname -f`  ]
then
      if [ ! -d /var/www/html/repo ]
      then
         mkdir -p /var/www/html/repo
      fi
      docker run -d --hostname localrepo --name localrepo -p 80:80 --privileged -v /var/www/html/repo:/usr/local/apache2/htdocs/ httpd:2.4
fi

cp docker-hdp-lab_service.sh /opt/docker_cluster
cp docker-hdp-lab.service /etc/systemd/system/
set +e
systemctl enable docker-hdp-lab.service
set -e

echo -e "\n\t Adding $PWD to \$PATH\n" 
export PATH=$PATH:$PWD
echo "PATH=$PATH" > /etc/profile.d/docker.sh
chmod +x /etc/profile.d/docker.sh
systemctl start docker-hdp-lab

echo "-----------------------------------------------------"
echo -e "\n\t $(tput setaf 2)Docker-HDP-Lab Setup is now Complete !$(tput sgr 0) \n"
echo "-----------------------------------------------------"
echo -e "\nNext, Build Ambari Images for various versions:: Run $(tput setaf 1)\"build_image.sh\"$(tput sgr 0) script for more help\n"
echo -e "\nAnd then Localize all the required HDP releases. For example: $(tput setaf 1)"
echo -e "\tlocalize_hdp.sh add 3.2.2.0 https://ad-odp.s3.us-west-1.amazonaws.com/Release/Stable/centos7/ODP/3.2.2.0-1.tar.gz"
echo -e "$(tput sgr 0)\n\n"
