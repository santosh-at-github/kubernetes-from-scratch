# Importent kubernetes Concepts and commands with example

## Kubernetes Installation pre-requsite:

1. If on CentOS, disable SELinux:
 $ setenforce 0
 $ sed -i --follow-symlinks 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/sysconfig/selinux

2. Enable the "br_netfilter" module for cluster communication.
 $ modprobe br_netfilter
 $ echo '1' > /proc/sys/net/bridge/bridge-nf-call-iptables
 $ systect -w net.bridge.bridge-nf-call-iptables=1

3. Ensure ip forwarding is enabled:
 $ echo 1 > /proc/sys/net/ipv4/ip_forward
 $ sysctl -w net.ipv4.ip_forward=1

4. Remove old docker and Install Docker dependencies
 $ apt-get remove docker docker-engine docker.io containerd runc
 $ apt install apt-transport-https ca-certificates curl gnupg-agent software-properties-common

5. Add docker gpg key, repo and install docker:
 $ curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
 $ add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
 $ apt-get update && apt-get install docker-ce docker-ce-cli containerd.io


## ETCD backup and restore
### Backup ETCD:
A ETCD Cluster can be easily backedup using etcdctl command line tool. If this is not installed by default, it can be installed from "https://github.com/coreos/etcd/releases/download/v3.3.9/etcd-v3.3.9-linux-amd64.tar.gz".

1.  To backup etcd use below command either on etcd node or on a node from which etcd endpoint is reachable:

  $ ETCDCTL_API=3 etcdctl --endpoints "https://172.31.64.23:2379,https://172.31.77.159:2379,https://172.31.70.52:2379" --cert /var/lib/kubernetes/kubernetes.pem --cacert /var/lib/kubernetes/ca.pem --key /var/lib/kubernetes/kubernetes-key.pem snapshot save /backup/etcd-snapshot-latest.db

  Note: The certoficate files can be found using the "ps-ef | grep etcd" command.

2. To easily restore a master node(s) from backup, only etcd backup is not sufficient. Kubernetes certificate (defaults at "/etc/kubernetes/pki") should also be backedup by just copying it to the backup directory.
3. You may also backup kubeadm configuration file (defaults at "/etc/kubeadm/kubeadm-config.yaml") if the cluster has been initiated using kubeadm to make restoration process smooth.

### Restore ETCD:

1. etcdclt command line tool can be used to restore etcd backup as below:

  $ ETCDCTL_API=3 etcdctl snapshot restore snapshot.db \
    --name m1 \
    --initial-cluster m1=http://host1:2380,m2=http://host2:2380,m3=http://host3:2380 \
    --initial-cluster-token etcd-cluster-1 \
    --initial-advertise-peer-urls http://host1:2380
  Note: Here m1 and host1 is the hostname and the host IP/DNS on which the back would be restored. Similar command should be run on all the etcd member host to complete the snapshot restoration process.
  Referance links:
    https://github.com/etcd-io/etcd/blob/master/Documentation/op-guide/recovery.md
    https://elastisys.com/2018/12/10/backup-kubernetes-how-and-why/

2. If the cluster has been initiated using kubeadm and kube config has been backed up, then after the etcd snapshot restore, following command can be used to re-initialize the master.

  $ sudo kubeadm init --ignore-preflight-errors=DirAvailable--var-lib-etcd \
    --config /etc/kubeadm/kubeadm-config.yaml

3. The backup and restore of the etcd cluster can be automated using kubernetes conjob.

## Create user for remote kubectl
Kubernetes do not have api to create user, instead it relies on certificate or 3rd party authntication to authenticate a user. Below are commands to create certificate for user and sign it with cluster CA.

1. Create User key:
  $ openssl genrsa -out user.pem 2048

2. Create CSR for the user:
  $ openssl req -new -key user.pem -our user.csr -subj "/CN=user/O=ops/O=example.org"

3. Generate the user certificate:
  $ openssl x509 -req -CA ca.pem -CAkey ca-key.pem -CAcreateserial -days 730 -in user.csr -out user.csr

4. After this configure kubectl to use this certificates.
  $ kubectl config set-credentials user --client-certificate=/absolute/path/to/user.crt --client-key=/absolute/path/to/user.key

  $ kubectl config set-cluster cluster_name --certificate-authority=$HOME/.kube/users/ca.pem --embed-certs --server=https://<API_Server_or_LB_IP>:6443

  $ kubectl config set-context my_context --cluster=cluster_name --user=user

  $ kubectl config use-context my_context

5. Then create role and rolebinding for the user.
$ cat <<EOF | kubectl create -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: user-role
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
EOF

$ cat <<EOF | kubectl create -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: user-rolebinding
roleRef:
  kind: Role
  name: user-role
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: User
  name: user
  apiGroup: rbac.authorization.k8s.io
EOF

OR use below kubectl command:
$ kubectl create rolebinding user-rolebinding --role=user-role --user=user
