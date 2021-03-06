#!/bin/bash
# CAM CE 2102 "online" install steps:-
# THIS SCRIPT ONLY WORKS FOR LINUX
# Run it on the ICP Master with kubectl configured
# We assume NFS is already installed, configured and running
# either run as root or as a sub-account with sudo configured for NOPASSWORD prompt
# usage: ./camQuick.sh 192.168.27.100 admin admin 6e150616-blah-blah-blah-758b1bc1fe9e

if [ $# -eq 0 ]; then
echo "Usage: $0 masterIp user password dockerAPIkey";
echo "";
echo "eg, ./camQuick.sh 192.168.27.100 admin admin 6e150616-blah-blah-blah-758b1bc1fe9e";
echo "";
echo "all options are required";
echo "masterIp = IP address of the ICP Master node";
echo "user = admin should do fine";
echo "username = admin user passsord, usually admin";
echo "dockerAPIkey = your docker account API key generated from cloud.docker.com/swarm";
echo "";
exit 1;
fi

MASTER_IP=$1
user_name=$2
pass=$3
API_KEY=$4

# download linux 'bx' CLI from IBM and install 
curl -fsSL https://clis.ng.bluemix.net/install/linux | bash

# download 'bx pr' plugin from your local ICP and install
wget https://$MASTER_IP:8443/api/cli/icp-linux-amd64 --no-check-certificate && bx plugin install icp-linux-amd64 -f

# download 'helm cli' from your local ICP and install 
wget https://$MASTER_IP:8443/helm-api/cli/linux-amd64/helm --no-check-certificate && sudo chmod 755 helm && sudo mv helm /usr/local/bin && helm init -c

# login to your cluster and configure helm cli with ICP certs
bx pr login -u $user_name -p $pass --skip-ssl-validation -c id-mycluster-account -a https://$MASTER_IP:8443 && bx pr cluster-config mycluster

# add ibm charts repo into help, update the repo and download the CAM chart
helm repo add ibm-stable https://raw.githubusercontent.com/IBM/charts/master/repo/stable/
helm repo update
helm fetch ibm-stable/ibm-cam-prod --version 1.2.0

# make the directories used for PVs, update /etc/exports with the locations, recycle NFS exports on the fly
sudo mkdir -p /export/CAM_logs && sudo mkdir -p /export/CAM_db && sudo mkdir -p /export/CAM_terraform && sudo mkdir -p /export/CAM_BPD_appdata
echo "/export/CAM_logs   *(rw,sync,no_subtree_check,async,insecure,no_root_squash)" | sudo tee --append /etc/exports
echo "/export/CAM_db     *(rw,sync,no_subtree_check,async,insecure,no_root_squash)" | sudo tee --append /etc/exports
echo "/export/CAM_terraform     *(rw,sync,no_subtree_check,async,insecure,no_root_squash)" | sudo tee --append /etc/exports
echo "/export/CAM_BPD_appdata     *(rw,sync,no_subtree_check,async,insecure,no_root_squash)" | sudo tee --append /etc/exports
sudo exportfs -a

# unpack the CAM chart and modify the PV files to include IP address and paths
tar xzf ibm-cam-prod-1.2.0.tgz && cd ibm-cam-prod/pre-install/
sed -i 's/<your PV ip>/'"$MASTER_IP"'/' *.yaml
sed -i 's-<your PV path>-/export/CAM_logs-' cam-logs-pv.yaml
sed -i 's-<your PV path>-/export/CAM_db-' cam-mongo-pv.yaml
sed -i 's-<your PV path>-/export/CAM_terraform-' cam-terraform-pv.yaml
sed -i 's-<your PV path>-/export/CAM_BPD_appdata-' cam-bpd-appdata-pv.yaml

# use kubectl to create the 4 PVs
kubectl create -f ./cam-mongo-pv.yaml 
kubectl create -f ./cam-logs-pv.yaml 
kubectl create -f ./cam-terraform-pv.yaml 
kubectl create -f ./cam-bpd-appdata-pv.yaml

# create the docker API key secret in ICP and patch the service account to use it
kubectl create secret docker-registry cam --docker-username=berenss --docker-password=$API_KEY --docker-email=berenss@us.ibm.com -n services
kubectl patch serviceaccount default -p '{"imagePullSecrets": [{"name": "cam"}]}' --namespace=services

# run the CAM CE deploy
cd && helm install --name cam ibm-cam-prod-1.2.0.tgz --namespace services --set arch=amd64 --set global.image.secretName=cam --tls

# check the pods status to ensure all are running
watch kubectl get -n services pods -o wide
