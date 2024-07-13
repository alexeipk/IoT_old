#!/usr/bin/bash

LOAD_BALANCER_PORT=8888
SSH_PORT=22
SSH_PORT_INTERNAL=32222

SRC_REPO_NAME=inspektor-aroque
SRC_REPO_URL=https://github.com/iwillenshofer/${SRC_REPO_NAME}.git

CLUSTERNAME="p3"

BLUE="\e[1;96m"
RED="\e[1;97m"
ENDCOLOR="\e[0m"

if [ "$#" -gt 0 ] && [ "$1" == "clean" ]; then
	echo -e "${BLUE}Cleaning Up...${ENDCOLOR}"
	echo -e "${RED}This might take a while...${ENDCOLOR}"
    sg docker -c "
        kubectl delete all --all
        kubectl delete namespace dev
        kubectl delete namespace argocd
        argocd argocd app delete inspektor-internal -y
        k3d cluster rm p3
    " &> /dev/null
	rm -rf ~/.kube &> /dev/null
    exit
fi

# Install required packages

# Add Docker's official GPG key
echo -e "${BLUE}Add Docker's official GPG key${ENDCOLOR}"
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add the repository to Apt sources
echo -e "${BLUE}Add the repository to Apt sources${ENDCOLOR}"
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update

# Install docker in host system
echo -e "${BLUE}Install Docker${ENDCOLOR}"
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin


# Post-installation steps for Linux
echo -e "${BLUE}Setting Groups${ENDCOLOR}"
sudo groupadd -f docker
sudo usermod -aG docker $USER

#Install k3d
sg docker -c "curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash"

# Install kubectl
echo -e "${BLUE}Install Kubectl${ENDCOLOR}"
sg docker -c '
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
'

# "Create k3d cluster"
echo -e "${BLUE}Create k3d cluster${ENDCOLOR}"
sg docker -c "k3d cluster create ${CLUSTERNAME} --api-port 6550 -p ${LOAD_BALANCER_PORT}:80@loadbalancer -p ${SSH_PORT}:${SSH_PORT_INTERNAL}@server:0 --servers 1 --agents 2 --kubeconfig-update-default --kubeconfig-switch-context"


# "Install ArgoCD CLI"
echo -e "${BLUE}Install ArgoCD CLI${ENDCOLOR}"
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sg docker -c 'sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd'
rm argocd-linux-amd64

echo -e "${BLUE}Apply ArgoCD${ENDCOLOR}"
sg docker -c "kubectl create namespace argocd"
sg docker -c "kubectl config set-context --current --namespace argocd"
sg docker -c "kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

# Patch Deployment
echo -e "${BLUE}Patch Deployment${ENDCOLOR}"
sg docker -c "
kubectl patch deployment argocd-server -n argocd -p '{\"spec\": {\"template\": {\"spec\": {\"containers\": [{\"name\": \"argocd-server\", \"args\": [\"/usr/local/bin/argocd-server\", \"--insecure\", \"--rootpath\", \"/argo-cd\"]}]}}}}'
"

#Wait for Kubectl
echo -e "${BLUE}Waiting for Kubectl${ENDCOLOR}"
sg docker -c 'kubectl wait --for=condition=Ready pod -l "app.kubernetes.io/name=argocd-server" -n argocd --timeout=300s'

#Apply Ingress Route
echo -e "${BLUE}Applying Ingress Route${ENDCOLOR}"

sg docker -c "
    kubectl apply -f ../confs/argocd.ingress.yaml
"

sg docker -c "argocd login --core"


echo -e "${BLUE}Add Cluster${ENDCOLOR}"
sg docker -c "
argocd cluster add k3d-${CLUSTERNAME} -y
"

# "Install inspektor application"
echo -e "${BLUE}Install inspektor application${ENDCOLOR}"

sg docker -c "
    kubectl create namespace dev
    argocd app create inspektor --repo ${SRC_REPO_URL} --path deployments --dest-server https://kubernetes.default.svc --sync-policy auto --dest-namespace dev
"

# Print ArgoCD cBLUEentials
echo -e "ArgoCD username:\nadmin\n"
echo -e "${BLUE}ArgoCD password:"
sg docker -c "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
