#!/bin/bash -x

Controller=$1

# Colour codes
Clr='\033[0m' # Clear
Bold='\033[1m'
Red='\033[0;31m'
Green='\033[0;32m'
Gb='\033[0;47m'

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

sudo apt-get update >/dev/null
sudo apt-get install -y nginx >/dev/null
sudo systemctl enable nginx
sudo mkdir -p /etc/nginx/tcpconf.d

echo "include /etc/nginx/tcpconf.d/*;" | sudo tee -a /etc/nginx/nginx.conf
cat << EOF | sudo tee /etc/nginx/tcpconf.d/kubernetes.conf >/dev/null
stream {
    upstream kubernetes {
    }
    server {
        listen 6443;
        listen 443;
        proxy_pass kubernetes;
    }
}
EOF
for ip in $(echo "$Controller" | awk -F: '{for(i=1;i<=NF;i++){split($i,a,","); print a[2]}}'); do
  sudo sed -i "/upstream kubernetes/a \ \ \ \ \ \ \ server $ip:6443;" /etc/nginx/tcpconf.d/kubernetes.conf
done
cat_file "/etc/nginx/tcpconf.d/kubernetes.conf"

sudo nginx -s reload
es=$?
exec_command 'Check if LoadBalancer is working fine' 'curl -s -k https://localhost:6443/version'
is_successful $es "Configuration of LoadBalancer"
