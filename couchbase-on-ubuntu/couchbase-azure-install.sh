#!/bin/bash

### Ercenk Keresteci (Full Scale 180 Inc)
### 
### Warning! This script partitions and formats disk information be careful where you run it
###          This script is currently under development and has only been tested on Ubuntu images in Azure
###          This script is not currently idempotent and only works for provisioning

# Log method to control/redirect log output
log()
{
    curl -X POST -H "content-type:text/plain" --data-binary "${HOSTNAME} - $1" https://logs-01.loggly.com/inputs/1ade465e-527c-40ab-a8b0-7c6f477af19a/tag/cb-extension,${HOSTNAME}
    echo $1
}

log "Begin execution of couchbase script extension on ${HOSTNAME}"
 
if [ "${UID}" -ne 0 ];
then
    log "Script executed without root permissions"
    echo "You must be root to run this program." >&2
    exit 3
fi

# TEMP FIX - Re-evaluate and remove when possible
# This is an interim fix for hostname resolution in current VM
if grep -q "${HOSTNAME}" /etc/hosts
then
  echo "${HOSTNAME}found in /etc/hosts"
else
  echo "${HOSTNAME} not found in /etc/hosts"
  # Append it to the hsots file if not there
  echo "127.0.0.1 $(hostname)" >> /etc/hosts
  log "hostname ${HOSTNAME} added to /etchosts"
fi

#Script Parameters
PACKAGE_NAME="couchbase-server-enterprise_3.0.3-ubuntu12.04_amd64.deb"
CLUSTER_NAME=""
IP_LIST=""
ADMINISTRATOR=""
PASSWORD=""
# Minimum VM size we are assuming is A2, which has 3.5GB, 2800MB is about 80% as recommended
RAM_FOR_COUCHBASE=0
IS_LAST_NODE=0

#Process the received arguments
while getopts d:n:i:a:p:r:l optname; do
    log "Option $optname set with value ${OPTARG}"
  case $optname in
    d) #Couchbase package name
      PACKAGE_NAME=${OPTARG}
      ;;
    n)  #set cluster name
      CLUSTER_NAME=${OPTARG}
      ;;
    i) #Static IPs of the cluster members
      IP_LIST=${OPTARG}
      ;;    
    a) #Adminsitrator name
      ADMINISTRATOR=${OPTARG}
      ;; 
	p) #Password for the admin
	  PASSWORD=${OPTARG}
	  ;;         
	r) #Recommended RAM amount
	  RAM_FOR_COUCHBASE=${OPTARG}
	  ;;              
	l) #is this for the last node?
	  IS_LAST_NODE=1
	  ;;        	  
  esac
done

# Install couchbase
install_cb()
{
	# First prepare the environment as per http://blog.couchbase.com/often-overlooked-linux-os-tweaks

	log "Disable swappiness"
	# We may not reboot, disable with the running system
	# Set the value for the running system
	echo 0 > /proc/sys/vm/swappiness

	# Backup sysctl.conf
	cp -p /etc/sysctl.conf /etc/sysctl.conf.`date +%Y%m%d-%H:%M`

	# Set the value in /etc/sysctl.conf so it stays after reboot.
	echo '' >> /etc/sysctl.conf
	echo '#Set swappiness to 0 to avoid swapping' >> /etc/sysctl.conf
	echo 'vm.swappiness = 0' >> /etc/sysctl.conf

	log "Disable THP"
	# Disble THP
	# We may not reboot yet, so disable for this time first
	# Disable THP on a running system
	echo never > /sys/kernel/mm/transparent_hugepage/enabled
	echo never > /sys/kernel/mm/transparent_hugepage/defrag

	# Backup rc.local
	cp -p /etc/rc.local /etc/rc.local.`date +%Y%m%d-%H:%M`
	sed -i -e '$i \ if test -f /sys/kernel/mm/transparent_hugepage/enabled; then \
 			 echo never > /sys/kernel/mm/transparent_hugepage/enabled \
		  fi \ \
		if test -f /sys/kernel/mm/transparent_hugepage/defrag; then \
		   echo never > /sys/kernel/mm/transparent_hugepage/defrag \
		fi \
		\n' /etc/rc.local
	

    log "Installing Couchbase package - $PACKAGE_NAME"    
	sudo dpkg -i ./$PACKAGE_NAME
}

DATA_DISKS="/datadisks"
DATA_MOUNTPOINT="$DATA_DISKS/disk1"
COUCHBASE_DATA="$DATA_MOUNTPOINT/couchbase"


# Stripe all of the data disks
bash ./vm-disk-utils-0.1.sh -b $DATA_DISKS -s

install_cb

mkdir -p "$COUCHBASE_DATA"
chown -R couchbase:couchbase "$COUCHBASE_DATA"
chmod 755 "$COUCHBASE_DATA"

IFS='-' read -a HOST_IPS <<< "$IP_LIST"

#Get the IP Addresses on this machine
declare -a MY_IPS=`ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1'`
MY_IP=""
declare -a MEMBER_IP_ADDRESSES=()
for (( n=0 ; n<("${HOST_IPS[1]}"+0) ; n++))
do
  HOST="${HOST_IPS[0]}${n}"
  if ! [[ "${MY_IPS[@]}" =~ "${HOST}" ]]; then
      MEMBER_IP_ADDRESSES+=($HOST)
  else
		MY_IP="${HOST}"
  fi
done

log "Is last node? ${IS_LAST_NODE}"
if [ "$IS_LAST_NODE" -eq 1 ]; then
	log "sleep for 4 minutes to wait for the environment to stabilize"
	sleep 4m

	log "Initializing the first node of the cluster on ${MY_IP}."
	/opt/couchbase/bin/couchbase-cli node-init -c "$MY_IP":8091 --node-init-data-path="${COUCHBASE_DATA}" -u "${ADMINISTRATOR}" -p "${PASSWORD}"
	log "Setting up cluster"
	/opt/couchbase/bin/couchbase-cli cluster-init -c "$MY_IP":8091  -u "${ADMINISTRATOR}" -p "${PASSWORD}" --cluster-init-port=8091 --cluster-init-ramsize="${RAM_FOR_COUCHBASE}"
	log "Setting autofailover"
	/opt/couchbase/bin/couchbase-cli setting-autofailover  -c "$MY_IP":8091  -u "${ADMINISTRATOR}" -p "${PASSWORD}" --enable-auto-failover=1 --auto-failover-timeout=30

	for (( i = 0; i < ${#MEMBER_IP_ADDRESSES[@]}; i++ )); do
		log "Adding node ${MEMBER_IP_ADDRESSES[$i]} to cluster"
		/opt/couchbase/bin/couchbase-cli server-add -c "$MY_IP":8091 -u "${ADMINISTRATOR}" -p "${PASSWORD}" --server-add="${MEMBER_IP_ADDRESSES[$i]}" 
	done

	log "Reblancing the cluster"
	/opt/couchbase/bin/couchbase-cli rebalance -c "$MY_IP":8091 -u "${ADMINISTRATOR}" -p "${PASSWORD}"
fi
log "Install couchbase complete!"