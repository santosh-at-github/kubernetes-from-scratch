#!/bin/bash

# This is the main script and it should be executed from the same diretory in which the scripts has been copied else it may not be able to locate other supporting script and execution may fail.
# This script has been design to work on AWS Cloud and it usages aws cli tool to create instances and tag it. So before running it make sure you have aws cli configured with enough permission to created instances and tag it.
# This script doesn't accept any parameter, if you need to change it's behaviour, change the applicable variable in the script.
# It only works on systemd instances.
# It creates kubernetes master and worker instances in a single subnet (availability zone)

if [[ $1 == '-d' ]]; then Verbose=1; else Verbose=0; fi

# Colour codes
Clr='\033[0m' # Clear
Bold='\033[1m'
Red='\033[0;31m'
Green='\033[0;32m'
Gb='\033[0;47m'

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
PrivateKeyLocation="~/Documents/Keys/MainPrivateKey"
ssh_options="-o StrictHostKeyChecking=no -i $PrivateKeyLocation -l $username"
script_dir=$(pwd)
rm_ins=''
tmp_ins_file='/tmp/my_ins'

###############################################################################
#                                 Functions                                   #
###############################################################################
cat_file(){
  file=$1
  echo -e "\nContent of file $file:"
  echo '\n========================================================'
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
    unset instance_id instance_ip instance_dns instance_pub_ip
    if [[ $Verbose -eq 1 ]]; then echo -e "\nLaunching of $resource_type$i instance started\n"; fi
    instance_id=$(aws ec2 run-instances --count 1 --image-id $image \
        --instance-type $instanceType --key-name $AwsKeyPairName --iam-instance-profile Name=$imaProfileName \
        --region $region --security-group-ids $securityGroup --subnet-id $subnetId --output text \
      --query 'Instances[*].InstanceId')
    for j in $(seq 10); do
      if [ -z $instance_ip ]; then
        instance_ip=$(aws ec2 describe-instances --instance-ids $instance_id \
          --query 'Reservations[*].Instances[*].PrivateIpAddress' --output text --region $region)
      fi
      if [ -z $instance_dns ]; then
        instance_dns=$(aws ec2 describe-instances --instance-ids $instance_id \
          --query 'Reservations[*].Instances[*].PrivateDnsName' --output text --region $region)
      fi
      if [ -z $instance_pub_ip ]; then
        instance_pub_ip=$(aws ec2 describe-instances --instance-ids $instance_id \
          --query 'Reservations[*].Instances[*].PublicIpAddress' --output text --region $region)
      fi
      if [ ! -z $instance_pub_ip ] && [ ! -z $instance_ip ] && [ ! -z $instance_dns ] && [ $j -le 9 ]; then
        break
      elif [ $j -le 9 ]; then
        sleep $j
      else
        echo "Couldn't get the public IP of $resource_type$i ($instance_id), aborting sript execution.."
      fi
    done

    aws ec2 create-tags --resources $instance_id --tags Key=Name,Value=$resource_type-$i --region $region
    eval "$resource_type$i=(\"$instance_id\" \"$instance_ip\" \"$instance_pub_ip\" \"$instance_dns\")"
    echo "$resource_type$i=(\"$instance_id\" \"$instance_ip\" \"$instance_pub_ip\" \"$instance_dns\")" >> $tmp_ins_file
    eval "$resource_type=\"\$$resource_type:$instance_id,$instance_ip,$instance_pub_ip,$instance_dns\""
    rm_ins="$rm_ins $instance_id"
  done

  is_successful $? "Create $resource_type resource"

  eval "$resource_type=\$(echo \$$resource_type | sed 's/^://g')"
  eval "echo $resource_type: \$$resource_type"
}

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

    if [[ $Verbose -eq 1 ]]; then
      echo -e "${Gb}$client_name-csr.json >>>"; cat $client_name-csr.json
      echo -e "$CFSSL gencert $options $client_name-csr.json  | $CFSSLJSON -bare $client_name${Clr}"
    fi
    $CFSSL gencert $options $client_name-csr.json  | $CFSSLJSON -bare $client_name

  done
  is_successful $? "Generated $client_name certificate"
}

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
    if [[ $Verbose -eq 1 ]]; then echo -e "${Gb}$CMD${Clr}"; fi
    $CMD >/dev/null
    CMD="$KUBECTL config set-credentials $credential${client_name} --client-certificate=${client_name}.pem \
      --client-key=${client_name}-key.pem --embed-certs=true --kubeconfig=${client_name}.kubeconfig"
    if [[ $Verbose -eq 1 ]]; then echo -e "${Gb}$CMD${Clr}"; fi
    $CMD >/dev/null
    CMD="$KUBECTL config set-context default --cluster=kubernetes-the-hard-way --user=$credential${client_name} \
      --kubeconfig=${client_name}.kubeconfig"
    if [[ $Verbose -eq 1 ]]; then echo -e "${Gb}$CMD${Clr}"; fi
    $CMD >/dev/null
    CMD="$KUBECTL config use-context default --kubeconfig=${client_name}.kubeconfig"
    if [[ $Verbose -eq 1 ]]; then echo -e "${Gb}$CMD${Clr}"; fi
    $CMD >/dev/null
    is_successful $? "Generate kubeconfig file for $client_name"
  done
}

# CA Certificate
generate_CA(){
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
  if [[ $Verbose -eq 1 ]]; then echo -e "${Gb}ca-config.json >>>"; cat ca-csr.json; echo -e "${Clr}"; fi
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

  if [[ $Verbose -eq 1 ]]; then
    echo -e "${Gb}ca-csr.json >>>"; cat ca-csr.json
    echo -e "${Gb}$CFSSL gencert -initca ca-csr.json  | $CFSSLJSON -bare ca${Clr}"
  fi
  $CFSSL gencert -initca ca-csr.json  | $CFSSLJSON -bare ca
  is_successful $? "Generated CA certificates"
}

encryption_config(){
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
if [[ $Verbose -eq 1 ]]; then
  echo -e "${Gb}encryption-config.yaml >>>"
  cat encryption-config.yaml
  echo -e "${Clr}"; fi
}

copy_certs(){
  # Move certificates to respective nodes
  for i in $(seq $worker_node_count); do
    eval client_name=(\${Worker$i[3]})
    eval ip=(\${Worker$i[2]})
    CMD="scp -q -o StrictHostKeyChecking=no -o User=$username -i $PrivateKeyLocation ca.pem \
      $client_name-key.pem $client_name.pem $client_name.kubeconfig kube-proxy.kubeconfig $ip:./"
    $CMD
    is_successful $? "File copy to Worker node $ip"
  done

  for i in $(seq $controller_node_count); do
    eval client_name=(\${Controller$i[3]})
    eval ip=(\${Controller$i[2]})
    CMD="scp -q -o StrictHostKeyChecking=no -o User=$username -i $PrivateKeyLocation ca.pem \
      ca-key.pem kubernetes-key.pem kubernetes.pem service-account-key.pem service-account.pem admin.kubeconfig \
      kube-controller-manager.kubeconfig kube-scheduler.kubeconfig encryption-config.yaml $ip:./"
    $CMD
    is_successful $? "File copy to Controller node $ip"
  done
}
# Install and configure ETCD on Controllers

install_etcd(){
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
}

configure_rbac(){
  # RBAC configuration for Kubelet Authorization
  # Sould be configured on only one of the Controller in the Cluster
  ssh $ssh_options ${Controller1[2]} "bash -s" < $script_dir/RABC_configuration.sh
  is_successful $? "Resource creation for RABC"
}

configure_lb(){
  # Load Balancer Configuration
  ssh $ssh_options ${LoadBalancer1[2]} "bash -s" < $script_dir/LoadBanalcer_Configuration.sh "$Controller"
}

configure_worker(){
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
}

setup_client(){
  # Setup Client
  scp -q -o StrictHostKeyChecking=no -o User=$username -i $PrivateKeyLocation \
    ca.pem admin-key.pem admin.pem ${Client1[2]}:./
  ssh $ssh_options ${Client1[2]} "bash -s" < $script_dir/Client.sh "${LoadBalancer1[1]}"

  is_successful $? "Kubernets Cluster configuration completed"
  echo -e "\nUse Client ${Client1[2]} to intreact woth your Kubernetes Cluster."
}

###############################################################################

work_dir=/tmp/dt_$(date +%Y%m%d)
mkdir -p $work_dir
cd $work_dir
CFSSL=$work_dir/cfssl
CFSSLJSON=$work_dir/cfssljson
KUBECTL=$work_dir/kubectl

if [ ! -s $CFSSL ]; then curl -s -o cfssl https://pkg.cfssl.org/R1.2/cfssl_darwin-amd64; fi
if [ ! -s $CFSSLJSON ]; then curl -s -o cfssljson https://pkg.cfssl.org/R1.2/cfssljson_darwin-amd64; fi
if [ ! -s $KUBECTL ]; then
  curl -s -o kubectl https://storage.googleapis.com/kubernetes-release/release/v1.12.0/bin/darwin/amd64/kubectl
fi
is_successful $? "Downloded Needed Binaries locally"
chmod u+x cfssl cfssljson kubectl


###############################################################################
#                       The Action starts from here                           #
###############################################################################

if [[ -z $CREATE_RESOURCES ]] || [[ $CREATE_RESOURCES -eq 0 ]]; then
  echo -e "\nUsing Dummy EC2 instance details.\nTo create actual EC2 instances, \
  export ENV variable ${Bold}CREATE_RESOURCES=1${Clr} before executing this script\n"

  ######## Temp Data #########
  if [ -s $tmp_ins_file ]; then
    . $tmp_ins_file
  else
    echo "Couldn't find $tmp_ins_file. Aborting."
    exit
  fi
  ############################

elif [[ $CREATE_RESOURCES -eq 1 ]]; then
  # Launch EC2 instance which will be used in the cluster
  > $tmp_ins_file # Reset the temp Instance file which records the launched instances
  create_resource 'Controller' $controller_node_count
  create_resource 'Worker' $worker_node_count
  create_resource 'LoadBalancer' 1
  create_resource 'Client' 1
fi
echo -e "\nInstance List\n$rm_ins\n"

#<<Comment1
generate_CA
# Admin, Kubelet, Controller Manager, Kube Proxy, Kube Scheduler Client certificates
client_cert 'admin'
client_cert 'Worker' "$worker_node_count"
client_cert 'kube-controller-manager'
client_cert 'kube-proxy'
client_cert 'kube-scheduler'
# Service Account Key Pair
client_cert 'service-account'
# API Server Certificate
client_cert 'Controller'
generate_kubeconfig 'Worker' $worker_node_count
generate_kubeconfig 'kube-proxy'
generate_kubeconfig 'kube-controller-manager'
generate_kubeconfig 'kube-scheduler'
generate_kubeconfig 'admin'
encryption_config

copy_certs
install_etcd
configure_rbac
configure_lb
configure_worker
setup_client

#Comment1

#install_etcd
