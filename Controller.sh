#!/bin/bash

controller_node_count="$1"
Controller="$2"
echo -e "controller_node_count: $controller_node_count\n Controller: $Controller"

# Colour codes
Clr='\[\033[0m\]' # Clear
Bold='\033[1m'
Red='\[\033[0;31m\]'
Green='\[\033[0;32m\]'

work_dir="$HOME"
cd $work_dir

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

is_running(){
  service=$1
  sudo systemctl is-active --quiet $service && echo -e "$service is $Green $Bold running $Clr\n" || \
    echo -e "$service is $Red $Bold not running $Clr\n"
}

# Install and configure ETCD
# yum install wget -y
sudo apt-get update -qq && sudo apt-get install wget -y -qq
wget -q --timestamping "https://github.com/coreos/etcd/releases/download/v3.3.9/etcd-v3.3.9-linux-amd64.tar.gz"
tar -xf etcd-v3.3.9-linux-amd64.tar.gz
sudo mv etcd-v3.3.9-linux-amd64/etcd* /usr/local/bin/
sudo mkdir -p /etc/etcd /var/lib/etcd
sudo cp ca.pem kubernetes-key.pem kubernetes.pem /etc/etcd/
is_successful $? "Installation of ETCD"

ETCD_NAME=$(curl -s http://169.254.169.254/latest/meta-data/local-hostname)
INTERNAL_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
for data in $(echo $Controller | awk -F: '{for(i=1;i<=NF;i++){print $i}}'); do
  INITIAL_CLUSTER="$INITIAL_CLUSTER,$(echo $data|cut -d ',' -f4)=https://$(echo $data|cut -d ',' -f2):2380"
  #eval "INITIAL_CLUSTER=$INITIAL_CLUSTER,\${Controller$i[3]}=https://\${Controller$i[1]}:2380"
done
INITIAL_CLUSTER="$(echo $INITIAL_CLUSTER|sed 's/^,//g')"

cat << EOF | sudo tee /etc/systemd/system/etcd.service > /dev/null
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
ExecStart=/usr/local/bin/etcd \\
  --name ${ETCD_NAME} \\
  --cert-file=/etc/etcd/kubernetes.pem \\
  --key-file=/etc/etcd/kubernetes-key.pem \\
  --peer-cert-file=/etc/etcd/kubernetes.pem \\
  --peer-key-file=/etc/etcd/kubernetes-key.pem \\
  --trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${INTERNAL_IP}:2380 \\
  --listen-peer-urls https://${INTERNAL_IP}:2380 \\
  --listen-client-urls https://${INTERNAL_IP}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${INTERNAL_IP}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster ${INITIAL_CLUSTER} \\
  --initial-cluster-state new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
cat_file "/etc/systemd/system/etcd.service"

sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd
is_successful $? "Configuration of ETCD"
sleep 2
is_running "etcd"
exec_command 'Cluster Member list:' 'sudo ETCDCTL_API=3 etcdctl member list --endpoints=https://127.0.0.1:2379 --cacert=/etc/etcd/ca.pem --cert=/etc/etcd/kubernetes.pem --key=/etc/etcd/kubernetes-key.pem'

#Install Kubernetes Control Plane compoenets
sudo mkdir -p /etc/kubernetes/config
wget -q --timestamping \
  "https://storage.googleapis.com/kubernetes-release/release/v1.10.2/bin/linux/amd64/kube-apiserver" \
  "https://storage.googleapis.com/kubernetes-release/release/v1.10.2/bin/linux/amd64/kube-controller-manager" \
  "https://storage.googleapis.com/kubernetes-release/release/v1.10.2/bin/linux/amd64/kube-scheduler" \
  "https://storage.googleapis.com/kubernetes-release/release/v1.10.2/bin/linux/amd64/kubectl"
chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl
sudo mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/
is_successful $? "Installation of Control Plane Compoenets"

#Configure API Server
sudo mkdir -p /var/lib/kubernetes/
sudo cp ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem service-account-key.pem service-account.pem \
  encryption-config.yaml /var/lib/kubernetes/
INTERNAL_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
for ip in $(echo "$Controller" | awk -F: '{for(i=1;i<=NF;i++){split($i,a,","); print a[2]}}'); do
  etcd_servers="$etcd_servers,https://$ip:2379"
done
etcd_servers=$(echo $etcd_servers|sed 's/^,//')
cat << EOF | sudo tee /etc/systemd/system/kube-apiserver.service > /dev/null
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${INTERNAL_IP} \\
  --allow-privileged=true \\
  --apiserver-count=$controller_node_count \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/ca.pem \\
  --enable-admission-plugins=Initializers,NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \\
  --enable-swagger-ui=true \\
  --etcd-cafile=/var/lib/kubernetes/ca.pem \\
  --etcd-certfile=/var/lib/kubernetes/kubernetes.pem \\
  --etcd-keyfile=/var/lib/kubernetes/kubernetes-key.pem \\
  --etcd-servers=$etcd_servers \\
  --event-ttl=1h \\
  --experimental-encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.pem \\
  --kubelet-client-certificate=/var/lib/kubernetes/kubernetes.pem \\
  --kubelet-client-key=/var/lib/kubernetes/kubernetes-key.pem \\
  --kubelet-https=true \\
  --runtime-config=api/all \\
  --service-account-key-file=/var/lib/kubernetes/service-account.pem \\
  --service-cluster-ip-range=10.32.0.0/24 \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem \\
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem \\
  --v=2 \\
  --kubelet-preferred-address-types=InternalIP,InternalDNS,Hostname,ExternalIP,ExternalDNS
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
cat_file "/etc/systemd/system/kube-apiserver.service"

# Configure Controller Manager
sudo cp kube-controller-manager.kubeconfig /var/lib/kubernetes/
cat << EOF | sudo tee /etc/systemd/system/kube-controller-manager.service > /dev/null
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --address=0.0.0.0 \\
  --cluster-cidr=10.200.0.0/16 \\
  --cluster-name=kubernetes \\
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.pem \\
  --cluster-signing-key-file=/var/lib/kubernetes/ca-key.pem \\
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --leader-elect=true \\
  --root-ca-file=/var/lib/kubernetes/ca.pem \\
  --service-account-private-key-file=/var/lib/kubernetes/service-account-key.pem \\
  --service-cluster-ip-range=10.32.0.0/24 \\
  --use-service-account-credentials=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
cat_file "/etc/systemd/system/kube-controller-manager.service"

# Configuring Kube-Scheduler
sudo cp kube-scheduler.kubeconfig /var/lib/kubernetes/
cat << EOF | sudo tee /etc/kubernetes/config/kube-scheduler.yaml > /dev/null
apiVersion: componentconfig/v1alpha1
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: "/var/lib/kubernetes/kube-scheduler.kubeconfig"
leaderElection:
  leaderElect: true
EOF
cat_file "/etc/kubernetes/config/kube-scheduler.yaml"

cat << EOF | sudo tee /etc/systemd/system/kube-scheduler.service > /dev/null
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --config=/etc/kubernetes/config/kube-scheduler.yaml \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
cat_file "/etc/systemd/system/kube-scheduler.service"

# Start the Kubernetes API server components
sudo systemctl daemon-reload
sudo systemctl enable kube-apiserver kube-controller-manager kube-scheduler
sudo systemctl start kube-apiserver kube-controller-manager kube-scheduler
is_successful $? "Configuration of Control Plane Compoenets"
for srv in "kube-apiserver" "kube-controller-manager" "kube-scheduler"; do
  is_running "$srv"
done
exec_command 'Components Status' "kubectl get componentstatuses --kubeconfig $work_dir/admin.kubeconfig"

# Configure HTTP Heathcheck for Kube API server
sudo apt-get install -qq -y nginx > /dev/null
cat > kubernetes.default.svc.cluster.local << EOF
server {
  listen      80;
  server_name kubernetes.default.svc.cluster.local;

  location /healthz {
     proxy_pass                    https://127.0.0.1:6443/healthz;
     proxy_ssl_trusted_certificate /var/lib/kubernetes/ca.pem;
  }
}
EOF
sudo mv kubernetes.default.svc.cluster.local /etc/nginx/sites-available/kubernetes.default.svc.cluster.local
sudo ln -s /etc/nginx/sites-available/kubernetes.default.svc.cluster.local /etc/nginx/sites-enabled/
sudo systemctl enable nginx
sudo systemctl restart nginx
is_successful $? "Installation and configuration of Nginx"
exec_command 'To confirm if Nginx is working fine' "curl -s -H 'Host: kubernetes.default.svc.cluster.local' -i http://127.0.0.1/healthz"

# Enable IP forwarding for networking setup
sudo sysctl net.ipv4.conf.all.forwarding=1
echo "net.ipv4.conf.all.forwarding=1" | sudo tee -a /etc/sysctl.conf
is_successful $? "IP Forwarding enabled"
