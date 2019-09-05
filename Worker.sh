#!/bin/bash

# Colour codes
Clr='\033[0m' # Clear
Bold='\033[1m'
Red='\033[0;31m'
Green='\033[0;32m'
Gb='\033[0;47m'

work_dir="$HOME"

cd $work_dir

# Functions
cat_file(){
  file=$1
  echo -e "\nContent of file $file:"
  echo '========================================================'
  cat $file
  echo '========================================================'
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

# Download Worker binaries
sudo apt-get -qq -o=Dpkg::Use-Pty=0 update -y
sudo apt-get -qq -o=Dpkg::Use-Pty=0 -y install socat conntrack ipset
wget -q --timestamping \
  https://github.com/kubernetes-incubator/cri-tools/releases/download/v1.0.0-beta.0/crictl-v1.0.0-beta.0-linux-amd64.tar.gz \
  https://storage.googleapis.com/kubernetes-the-hard-way/runsc \
  https://github.com/opencontainers/runc/releases/download/v1.0.0-rc5/runc.amd64 \
  https://github.com/containernetworking/plugins/releases/download/v0.6.0/cni-plugins-amd64-v0.6.0.tgz \
  https://github.com/containerd/containerd/releases/download/v1.1.0/containerd-1.1.0.linux-amd64.tar.gz \
  https://storage.googleapis.com/kubernetes-release/release/v1.10.2/bin/linux/amd64/kubectl \
  https://storage.googleapis.com/kubernetes-release/release/v1.10.2/bin/linux/amd64/kube-proxy \
  https://storage.googleapis.com/kubernetes-release/release/v1.10.2/bin/linux/amd64/kubelet
sudo mkdir -p \
  /etc/cni/net.d \
  /opt/cni/bin \
  /var/lib/kubelet \
  /var/lib/kube-proxy \
  /var/lib/kubernetes \
  /var/run/kubernetes
chmod +x kubectl kube-proxy kubelet runc.amd64 runsc
sudo mv runc.amd64 runc
sudo mv kubectl kube-proxy kubelet runc runsc /usr/local/bin/
sudo tar -xf crictl-v1.0.0-beta.0-linux-amd64.tar.gz -C /usr/local/bin/
sudo tar -xf cni-plugins-amd64-v0.6.0.tgz -C /opt/cni/bin/
sudo tar -xf containerd-1.1.0.linux-amd64.tar.gz -C /
is_successful $? "Installation of Worker binaries"

# Configure Containerd
sudo mkdir -p /etc/containerd/
cat << EOF | sudo tee /etc/containerd/config.toml >/dev/null
[plugins]
  [plugins.cri.containerd]
    snapshotter = "overlayfs"
    [plugins.cri.containerd.default_runtime]
      runtime_type = "io.containerd.runtime.v1.linux"
      runtime_engine = "/usr/local/bin/runc"
      runtime_root = ""
    [plugins.cri.containerd.untrusted_workload_runtime]
      runtime_type = "io.containerd.runtime.v1.linux"
      runtime_engine = "/usr/local/bin/runsc"
      runtime_root = "/run/containerd/runsc"
EOF
cat_file "/etc/containerd/config.toml"

cat << EOF | sudo tee /etc/systemd/system/containerd.service >/dev/null
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target

[Service]
ExecStartPre=/sbin/modprobe overlay
ExecStart=/bin/containerd
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
OOMScoreAdjust=-999
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF
cat_file "/etc/systemd/system/containerd.service"

# Configure Kubelet
HOSTNAME=$(curl -s http://169.254.169.254/latest/meta-data/local-hostname)
sudo mv ${HOSTNAME}-key.pem ${HOSTNAME}.pem /var/lib/kubelet/
sudo mv ${HOSTNAME}.kubeconfig /var/lib/kubelet/kubeconfig
sudo mv ca.pem /var/lib/kubernetes/
cat << EOF | sudo tee /var/lib/kubelet/kubelet-config.yaml >/dev/null
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubernetes/ca.pem"
authorization:
  mode: Webhook
clusterDomain: "cluster.local"
clusterDNS:
  - "10.32.0.10"
runtimeRequestTimeout: "15m"
tlsCertFile: "/var/lib/kubelet/${HOSTNAME}.pem"
tlsPrivateKeyFile: "/var/lib/kubelet/${HOSTNAME}-key.pem"
EOF
cat_file "/var/lib/kubelet/kubelet-config.yaml"

cat << EOF | sudo tee /etc/systemd/system/kubelet.service >/dev/null
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --container-runtime=remote \\
  --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \\
  --image-pull-progress-deadline=2m \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --network-plugin=cni \\
  --register-node=true \\
  --v=2 \\
  --hostname-override=${HOSTNAME} \\
  --allow-privileged=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
cat_file "/etc/systemd/system/kubelet.service"

# Configure Kube-Proxy
sudo mv kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig
cat << EOF | sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml >/dev/null
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/var/lib/kube-proxy/kubeconfig"
mode: "iptables"
clusterCIDR: "10.200.0.0/16"
EOF
cat_file "/var/lib/kube-proxy/kube-proxy-config.yaml"

cat << EOF | sudo tee /etc/systemd/system/kube-proxy.service >/dev/null
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
cat_file "/etc/systemd/system/kube-proxy.service"

sudo systemctl daemon-reload
sudo systemctl enable containerd kubelet kube-proxy
sudo systemctl start containerd kubelet kube-proxy
is_successful $? "Configuration of Worker components"
is_running "containerd"
is_running "kubelet"
is_running "kube-proxy"

# Enable IP forwarding for networking setup
sudo sysctl net.ipv4.conf.all.forwarding=1
echo "net.ipv4.conf.all.forwarding=1" | sudo tee -a /etc/sysctl.conf
is_successful $? "IP Forwarding enabled"
