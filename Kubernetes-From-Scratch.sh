#!/bin/bash

# This is the main script and it should be executed from the same diretory in which the scripts has been copied else it may not be able to locate other supporting script and execution may fail.
# This script has been design to work on AWS Cloud and it usages aws cli tool to create instances and tag it. So before running it make sure you have aws cli configured with enough permission to created instances and tag it.
# This script doesn't accept any parameter, if you need to change it's behaviour, change the applicable variable in the script.
# It only works on systemd instances.

# Colour codes
Clr='\[\033[0m\]' # Clear
Bold='\033[1m'
Red='\[\033[0;31m\]'
Green='\[\033[0;32m\]'

worker_node_count=3
controller_node_count=3
username='ubuntu'
region='us-east-1'
image='ami-0cfee17793b08a293'
instanceType='t2.large'
AwsKeyPairName='MainPubKey'
imaProfileName='Ec2-Instance-Role'
securityGroup='sg-83b616fa'
subnetId='subnet-0cc0beca7c5c9b5ee'
PrivateKeyLocation='~/Documents/Keys/MainPrivateKey'

rm_ins=''
ssh_options="-o StrictHostKeyChecking=no -i $PrivateKeyLocation -l $username"
#script_dir=$(dirname $0)
script_dir=$(pwd)

# Functions
cat_file(){
  file=$1
  echo -e "\nContent of file $file:"
  echo '========================================================'
  cat $file
  echo -e '========================================================\n'
}

exec_command(){
  message=$1
  command=$2
  echo -e "\n$message:"
  echo '========================================================'
  echo "$command"
  $command
  echo -e '========================================================\n'
}

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

create_resource(){
  resource_type=$1
  count=$2
  for i in $(seq $count); do
    instance_id=$(aws ec2 run-instances --count 1 --image-id $image \
      --instance-type $instanceType --key-name $AwsKeyPairName --iam-instance-profile Name=$imaProfileName \
      --region $region --security-group-ids $securityGroup --subnet-id $subnetId --output text \
      --query 'Instances[*].InstanceId')
    instance_ip=$(aws ec2 describe-instances --instance-ids $instance_id \
      --query 'Reservations[*].Instances[*].PrivateIpAddress' --output text --region $region)
    instance_pub_ip=$(aws ec2 describe-instances --instance-ids $instance_id \
      --query 'Reservations[*].Instances[*].PublicIpAddress' --output text --region $region)
    instance_dns=$(aws ec2 describe-instances --instance-ids $instance_id \
      --query 'Reservations[*].Instances[*].PrivateDnsName' --output text --region $region)
    aws ec2 create-tags --resources $instance_id --tags Key=Name,Value=$resource_type-$i --region $region
    eval "$resource_type$i=(\"$instance_id\" \"$instance_ip\" \"$instance_pub_ip\" \"$instance_dns\")"
    eval "$resource_type=\"\$$resource_type:$instance_id,$instance_ip,$instance_pub_ip,$instance_dns\""
    rm_ins="$rm_ins $instance_id"
  done

  is_successful $? "Create $resource_type resource"

  eval "$resource_type=\$(echo \$$resource_type | sed 's/^://g')"
  eval "echo $resource_type: \$$resource_type"
}

create_resource 'Controller' $controller_node_count
create_resource 'Worker' $worker_node_count
create_resource 'LoadBalancer' 1
create_resource 'Client' 1

# This is my custom command, might not work for you.
echo -e "\nTo delete Cluster Resources use below command:\n ec2kill $rm_ins"

######## Temp Data #########
# Controller1=("i-0c2c638fed098747e" "172.31.77.231" "52.3.231.179" "ip-172-31-77-231.ec2.internal")
# Controller2=("i-0fc549cf56f55031a" "172.31.77.147" "3.216.79.200" "ip-172-31-77-147.ec2.internal")
# Controller3=("i-02250b514e34fb8c8" "172.31.71.194" "34.205.75.217" "ip-172-31-71-194.ec2.internal")
# Worker1=("i-012aa87d18a3630cc" "172.31.76.255" "" "ip-172-31-76-255.ec2.internal")
# Worker2=("i-0da8969265e011880" "172.31.70.185" "34.231.240.230" "ip-172-31-70-185.ec2.internal")
# Worker3=("i-01904d520b5a1e40e" "172.31.71.5" "3.92.152.24" "ip-172-31-71-5.ec2.internal")
# LoadBalancer1=("i-05a6294d4b5e28471" "172.31.64.104" "35.170.57.43" "ip-172-31-64-104.ec2.internal")
# Client1=("i-0207e0a9b65c2861a" "172.31.79.245" "18.205.7.227" "ip-172-31-79-245.ec2.internal")
# Controller="${Controller1[@]}:${Controller2[@]}:${Controller3[@]}"
# Controller="$(echo $Controller | sed 's/ /,/g')"
# Worker="${Worker1[@]}:${Worker2[@]}:${Worker3[@]}"
# Worker="$(echo $Worker | sed 's/ /,/g')"
############################

work_dir=/tmp/dt_$(date +%Y%m%d)
mkdir -p $work_dir
cd $work_dir
curl -s -o cfssl https://pkg.cfssl.org/R1.2/cfssl_darwin-amd64
curl -s -o cfssljson https://pkg.cfssl.org/R1.2/cfssljson_darwin-amd64
curl -s -o kubectl https://storage.googleapis.com/kubernetes-release/release/v1.12.0/bin/darwin/amd64/kubectl
is_successful $? "Downloded Needed Binaries locally"

chmod u+x cfssl cfssljson kubectl

CFSSL=$work_dir/cfssl
CFSSLJSON=$work_dir/cfssljson
KUBECTL=$work_dir/kubectl

# CA Certificate
{
cat > ca-config.json <<EOF
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF

cat > ca-csr.json <<EOF
{
  "CN": "Kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "CA",
      "ST": "Oregon"
    }
  ]
}
EOF

$CFSSL gencert -initca ca-csr.json  | $CFSSLJSON -bare ca
}
is_successful $? "Generated CA certificates"

# Kubelet Client Certificates for Workers
# Controller Manager Client certificate
# Kube Proxy Client certificate
# Kube Scheduler Client Certificate
# Admin Client Certificate
# Service Account Key Pair
# API Server Certificate
client_cert(){
  client_name=$1
  options="-ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes"
  if [ -z $2 ]; then count=1; else count=$2; fi
  if [[ "$client_name" == 'admin' ]]; then
    cn_name='admin'
    o_name='system:masters'
  elif [[ "$client_name" == 'kube-proxy' ]]; then
    cn_name="system:$client_name"
    o_name='system:node-proxier'
  elif [[ "$client_name" == 'service-account' ]]; then
    cn_name='service-accounts'
    o_name='Kubernetes'
  elif [[ "$client_name" == 'Controller' ]]; then
    client_name='kubernetes'
    cn_name='kubernetes'
    o_name='Kubernetes'
    CERT_HOSTNAME="10.32.0.1,${LoadBalancer1[1]}"
    for i in $(seq $controller_node_count); do
      eval name=(\${Controller$i[3]})
      eval ip=(\${Controller$i[1]})
      CERT_HOSTNAME="$CERT_HOSTNAME,$ip,$name";
    done
    CERT_HOSTNAME="$CERT_HOSTNAME,127.0.0.1,localhost,kubernetes.default"
    options="$options -hostname=${CERT_HOSTNAME}"
  else
    cn_name="system:$client_name"
    o_name=$cn_name
  fi
for i in $(seq $count); do
  if [[ "$client_name" =~ 'Worker' ]] || [[ "$client_name" =~ 'ip-' ]]; then
    unset options
    eval client_name=(\${Worker$i[3]})
    eval client_ip=(\${Worker$i[1]})
    cn_name="system:node:$client_name"
    o_name='system:nodes'
    options="-ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -hostname=$client_ip,$client_name -profile=kubernetes"
  fi
cat > $client_name-csr.json << EOF
{
  "CN": "$cn_name",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "$o_name",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

$CFSSL gencert $options $client_name-csr.json  | $CFSSLJSON -bare $client_name

done
is_successful $? "Generated $client_name certificate"
}

client_cert 'admin'
client_cert 'Worker' "$worker_node_count"
client_cert 'kube-controller-manager'
client_cert 'kube-proxy'
client_cert 'kube-scheduler'
client_cert 'Controller'
client_cert 'service-account'

# Generate a kubeconfig file
generate_kubeconfig(){
  name=$1
  count=$2
  if [ -z $2 ]; then count=1; else count=$2; fi
  if [ "$name" == 'Worker' ]; then
    server=${LoadBalancer1[1]}; credential="system:node:"
  elif [ "$name" == 'kube-proxy' ]; then
    server=${LoadBalancer1[1]}; credential="system:"
  elif [ "$name" == 'admin' ]; then
    server='127.0.0.1'; credential=""
  else
    server='127.0.0.1'; credential="system:"
  fi
  client_name=$name
  for i in $(seq $count); do
    if [ $name == 'Worker' ]; then eval client_name=(\${Worker$i[3]}); fi
    CMD="$KUBECTL config set-cluster kubernetes-the-hard-way --certificate-authority=ca.pem --embed-certs=true \
      --server=https://$server:6443 --kubeconfig=${client_name}.kubeconfig"
    $CMD >/dev/null
    CMD="$KUBECTL config set-credentials $credential${client_name} --client-certificate=${client_name}.pem \
      --client-key=${client_name}-key.pem --embed-certs=true --kubeconfig=${client_name}.kubeconfig"
    $CMD >/dev/null
    CMD="$KUBECTL config set-context default --cluster=kubernetes-the-hard-way --user=$credential${client_name} \
      --kubeconfig=${client_name}.kubeconfig"
    $CMD >/dev/null
    CMD="$KUBECTL config use-context default --kubeconfig=${client_name}.kubeconfig"
    $CMD >/dev/null
    is_successful $? "Generate kubeconfig file for $client_name"
  done
}
generate_kubeconfig 'Worker' $worker_node_count
generate_kubeconfig 'kube-proxy'
generate_kubeconfig 'kube-controller-manager'
generate_kubeconfig 'kube-scheduler'
generate_kubeconfig 'admin'

# Kubernetes Data encrpytion config file
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

cat > encryption-config.yaml << EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF

# Move certificates to respective nodes
for i in $(seq $worker_node_count); do
  eval client_name=(\${Worker$i[3]})
  eval ip=(\${Worker$i[2]})
  CMD="scp -q -o StrictHostKeyChecking=no -o User=$username -i $PrivateKeyLocation ca.pem \
    $client_name-key.pem $client_name.pem $client_name.kubeconfig kube-proxy.kubeconfig $ip:~/"
  $CMD
  is_successful $? "File copy to Worker node $ip"
done

for i in $(seq $controller_node_count); do
  eval client_name=(\${Controller$i[3]})
  eval ip=(\${Controller$i[2]})
  CMD="scp -q -o StrictHostKeyChecking=no -o User=$username -i $PrivateKeyLocation ca.pem \
    ca-key.pem kubernetes-key.pem kubernetes.pem service-account-key.pem service-account.pem admin.kubeconfig \
    kube-controller-manager.kubeconfig kube-scheduler.kubeconfig encryption-config.yaml $ip:~/"
  $CMD
  is_successful $? "File copy to Controller node $ip"
done

# Install and configure ETCD on Controllers
for i in $(seq $controller_node_count); do
  eval ip=(\${Controller$i[2]})
  echo -e "\nConfigure Controller $ip\n"
  echo "###############################"
  ssh $ssh_options $ip "bash -s" < $script_dir/Controller.sh $controller_node_count "$Controller"
done

sleep 15
echo -e "\n\nCheck if all Controller components are working fine:"
echo "++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
for i in $(seq $controller_node_count); do
  eval ip=(\${Controller$i[2]})
  echo -e "\nController $ip"
  echo -e "\nETCD Member list:"
  ssh $ssh_options $ip "sudo ETCDCTL_API=3 etcdctl member list --endpoints=https://127.0.0.1:2379 --cacert=/etc/etcd/ca.pem --cert=/etc/etcd/kubernetes.pem --key=/etc/etcd/kubernetes-key.pem"
  echo -e "\n componentstatuses and API health"
  ssh $ssh_options $ip "kubectl get componentstatuses --kubeconfig \$HOME/admin.kubeconfig; curl -s -H 'Host: kubernetes.default.svc.cluster.local' -i http://127.0.0.1/healthz"
done

# RBAC configuration for Kubelet Authorization
# Sould be configured on only one of the Controller in the Cluster
ssh $ssh_options ${Controller1[2]} "bash -s" < $script_dir/RABC_configuration.sh
is_successful $? "Resource creation for RABC"

# Load Balancer Configuration
ssh $ssh_options ${LoadBalancer1[2]} "bash -s" < $script_dir/LoadBanalcer_Configuration.sh "$Controller"

# Worker Nodes Configuration
for i in $(seq $worker_node_count); do
  eval ip=(\${Worker$i[2]})
  echo -e "\nConfigure Worker $ip\n"
  echo "###############################"
  ssh $ssh_options $ip "bash -s" < $script_dir/Worker.sh
  echo
done

echo -e "\nCheck if all worker has registered with Controller:"
ssh $ssh_options ${Controller1[2]} "kubectl get nodes"


# Setup Client
scp -q -o StrictHostKeyChecking=no -o User=$username -i $PrivateKeyLocation \
  ca.pem admin-key.pem admin.pem ${Client1[2]}:~/
ssh $ssh_options ${Client1[2]} "bash -s" < $script_dir/Client.sh "${LoadBalancer1[1]}"

is_successful $? "Kubernets Cluster configuration completed"
echo -e "\nUse Client ${Client1[2]} to intreact woth your Kubernetes Cluster."
