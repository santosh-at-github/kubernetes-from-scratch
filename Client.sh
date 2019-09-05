#!/bin/bash

LoadBalancer="$1"

# Colour codes
Clr='\033[0m' # Clear
Bold='\033[1m'
Red='\033[0;31m'
Green='\033[0;32m'
Gb='\033[0;47m'

is_successful(){
  es=$1
  message=$2
  printf "%s\t" "$message"
  if [ $es -eq 0 ]; then
    echo -e "$Green $Bold OK $Clr\n"
  else
    echo -e "$Red $Bold FAILED $Clr\n"
  fi
}

is_running(){
  service=$1
  sudo systemctl is-active --quiet $service && echo -e "$service is $Green $Bold running $Clr\n" || \
    echo -e "$service is $Red $Bold not running $Clr\n"
}

curl -s -o kubectl https://storage.googleapis.com/kubernetes-release/release/v1.10.2/bin/linux/amd64/kubectl
sudo chmod +x kubectl
sudo mv kubectl /usr/local/bin/

kubectl config set-cluster kubernetes-the-hard-way \
  --certificate-authority=$HOME/ca.pem \
  --embed-certs=true \
  --server=https://$LoadBalancer:6443

kubectl config set-credentials admin \
  --client-certificate=$HOME/admin.pem \
  --client-key=$HOME/admin-key.pem

kubectl config set-context kubernetes-the-hard-way \
  --cluster=kubernetes-the-hard-way \
  --user=admin

kubectl config use-context kubernetes-the-hard-way

is_successful $? 'Setup kubectl on Client'

CMD="kubectl get pods"
echo -e "\n\n$CMD"
$CMD
CMD="kubectl get nodes"
echo -e "\n$CMD"
$CMD
CMD="kubectl version"
echo -e "\n$CMD\n"
$CMD

# Setup Networking
ver="$(kubectl version | base64 | tr -d '\n')"
kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=${ver}&env.IPALLOC_RANGE=10.200.0.0/16"
is_successful $? 'Networking setup'

# Now check if the networking was created properly
sleep 15
CMD='kubectl get pods -n kube-system'
echo -e "\n$CMD"
$CMD
CMD='kubectl get nodes'
echo -e "\n$CMD"
$CMD

# Setup Kube-DNS
kubectl create -f https://storage.googleapis.com/kubernetes-the-hard-way/kube-dns.yaml
is_successful $? 'Kube-DNS setup'
kubectl get pods -l k8s-app=kube-dns -n kube-system
