
### Installation
# Prep host :
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
EOF

sudo swapoff -a
sudo vim /etc/fstab

# for issues on namespaces : https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/#known-issues
# You can explicitly configure DNS settings in NetworkManager to ensure that it does not add more nameservers than necessary. Create or edit a file in /etc/NetworkManager/conf.d/ to specify DNS settings.

# For example, create a file /etc/NetworkManager/conf.d/dns.conf with the following content:
# [main]
# dns=none
# rc-manager=unmanaged

# install CRI: 
sudo dnf remove docker \
                  docker-client \
                  docker-client-latest \
                  docker-common \
                  docker-latest \
                  docker-latest-logrotate \
                  docker-logrotate \
                  docker-engine -y


sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

sudo dnf install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y

sudo systemctl enable --now docker 

# Configure CRI
sudo sh -c 'containerd config default > /etc/containerd/config.toml'

sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd

# to check: containerd config dump | grep -A 12 -e '\[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options\]'

# Install kubelet kubeadm kubectl 
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

sudo yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes

sudo systemctl enable --now kubelet

sudo kubeadm init --pod-network-cidr=10.128.0.0/16

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/tigera-operator.yaml

# to download for custom pod network 
wget https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/custom-resources.yaml 

# replace with your ip
sed -i 's/cidr: 192\.168\.0\.0\/16/cidr: 10.128.0.0\/16/g' custom-resources.yaml

kubectl apply -f custom-resources.yaml

watch kubectl get pods -n calico-system

# for single nodes:
kubectl taint nodes --all node-role.kubernetes.io/control-plane-


### Remove/reset your cluster:
echo "y" | sudo kubeadm reset

sudo rm -rf /etc/cni/net.d 

sudo rm -rf ~/.kube


### Uprgrade Process:
## Specific version: (for upgrade) 
# change to a specific version:
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

sudo yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes

sudo systemctl enable --now kubelet

##  Actual Uprgrade Process:
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

sudo yum install -y kubeadm-'1.32.*-*' --disableexcludes=kubernetes

sudo kubeadm upgrade plan

sudo kubeadm upgrade apply v1.32.* -y

kubectl drain playground --ignore-daemonsets

sudo yum install -y kubelet-'1.32.*-*' kubectl-'1.32.*-*' --disableexcludes=kubernetes

sudo systemctl daemon-reload

sudo systemctl restart kubelet

kubectl uncordon playground 


### Backup
# Download the etcd command line tools
ETCD_VER=v3.5.18

GOOGLE_URL=https://storage.googleapis.com/etcd
GITHUB_URL=https://github.com/etcd-io/etcd/releases/download
DOWNLOAD_URL=${GOOGLE_URL}

rm -f /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz
rm -rf /tmp/etcd-download-test && mkdir -p /tmp/etcd-download-test

curl -L ${DOWNLOAD_URL}/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz -o /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz
tar xzvf /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz -C /tmp/etcd-download-test --strip-components=1

sudo mv /tmp/etcd-download-test/etcdctl /usr/local/bin/etcdctl
sudo mv /tmp/etcd-download-test/etcdutl /usr/local/bin/etcdutl

# clean up
rm -f /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz
rm -rf /tmp/etcd-download-test

sudo ETCDCTL_API=3 /usr/local/bin/etcdctl --endpoints=https://127.0.0.1:2379 \
--cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
snapshot save snapshot.db

etcdutl --write-out=table snapshot status snapshot.db 

## restore from a backup
# Create a data directory (where to put the backup)
sudo mkdir /var/lib/etcd-backup

sudo ETCDCTL_API=3 /usr/local/bin/etcdctl --data-dir="/var/lib/etcd-backup" \
--endpoints=https://127.0.0.1:2379 \
--cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
snapshot restore snapshot.db

# edit etcd.yaml to use the data directory, specifically the fields 
# --data-directory 
# volumeMounts.mountPath
# volumes.hostPath.path (etcd-data volume)

