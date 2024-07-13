#!/usr/bin/bash

LOAD_BALANCER_PORT=8888
BLUE="\e[1;96m"
RED="\e[1;97m"
ENDCOLOR="\e[0m"
DOMAIN=localhost

#repository name to be created and added to argo-cd
SRC_REPO_NAME=inspektor-aroque

# cleans up, in case its already set up
if [ "$#" -gt 0 ] && [ "$1" == "clean" ]; then
    echo -e "${BLUE}Cleaning Up...${ENDCOLOR}"
    echo -e "${RED}This might take a while if a gitlab instance was already created${ENDCOLOR}"
    sg docker -c "
        kubectl delete secrets --all -ngitlab
        kubectl delete all --all -ngitlab
        helm uninstall gitlab -ngitlab
        kubectl delete namespace gitlab
        argocd app delete inspektor-internal -y
        kubectl delete inspektor-internal
    " &> /dev/null
    exit
fi


#for webservice connection
PASSWORD=$(head -c 512 /dev/urandom | LC_CTYPE=C tr -cd 'a-zA-Z0-9' | head -c 32)

#for http and api connections
PERSONAL_TOKEN=$(head -c 512 /dev/urandom | LC_CTYPE=C tr -cd 'a-zA-Z0-9' | head -c 20)

#create key for ssh connections
rm $HOME/.ssh/gitlab
ssh-keygen -trsa -N "" -f "$HOME/.ssh/gitlab"
SSHKEY=$(cat $HOME/.ssh/gitlab.pub)


#Install Helm
sudo echo -e "${BLUE}Install Helm${ENDCOLOR}"
curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
sudo apt-get install apt-transport-https --yes
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update && sudo apt-get install -y helm


#Install Gitlab CLI
echo -e "${BLUE}Install Gitlab CLI${ENDCOLOR}"
GLAB="glab_1.36.0_$(uname -s)_$(uname -m).tar.gz"
curl -LO "https://gitlab.com/gitlab-org/cli/-/releases/v1.36.0/downloads/${GLAB}"
tar -xzf ${GLAB}
sudo install -o root -g root -m 0755 bin/glab /usr/local/bin/glab


echo -e "${BLUE}Setting Up gitlab...${ENDCOLOR}"
sg docker -c "
kubectl create namespace gitlab
kubectl create secret generic gitlab-gitlab-initial-root-password --from-literal=password=${PASSWORD} -n gitlab
helm repo add gitlab https://charts.gitlab.io/
helm repo update
helm upgrade --install gitlab gitlab/gitlab \
		--timeout 600s -f '../confs/values.yaml' \
		--set global.hosts.domain=${DOMAIN} \
		--namespace gitlab
"

echo -e "${RED}root${ENDCOLOR} user password: ${RED}"
sg docker -c "
    kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -ojsonpath='{.data.password}' | base64 -d ; echo
"
echo -e "${ENDCOLOR}"

#waits for the toolbox pod to be up
echo -e "${BLUE}Waiting for Gitlab toolbox pod to be ready${ENDCOLOR}"
sg docker -c "
    kubectl wait --for=condition=Ready pod -l "app=toolbox" -n gitlab  --timeout=700s
"

#waits for the web pod to be up
echo -e "${BLUE}Waiting for Gitlab Webservice pod to be ready${ENDCOLOR}"
sg docker -c "
    kubectl wait --for=condition=Ready pod -l "app=webservice" -n gitlab  --timeout=600s
"

#adds personal token to root user
echo -e "${BLUE}Remove Personal Token if exists${ENDCOLOR}"
sg docker -c "
    kubectl exec $(kubectl get pods -l app=toolbox -n gitlab -o name) -ngitlab -ctoolbox -- gitlab-rails runner \"user=User.find_by_username('root'); user.personal_access_tokens.delete_all; user.save!\"
"
echo -e "${BLUE}Setting up Personal Token${ENDCOLOR}"
sg docker -c "
    kubectl exec -ti $(kubectl get pods -l app=toolbox -n gitlab -o name) -ngitlab -ctoolbox -- gitlab-rails runner \"token=User.find_by_username('root').personal_access_tokens.create(scopes: ['write_repository', 'api'], name: 'Automation token', expires_at: 365.days.from_now); token.set_token('${PERSONAL_TOKEN}'); token.save!; token;\"
"
echo -e "Personal Token: ${BLUE}${PERSONAL_TOKEN}${ENDCOLOR}"

#Config Gitlab CLI
echo -e "${BLUE}Config Gitlab CLI${ENDCOLOR}"
cat <<EOF > ~/.config/glab-cli/config.yml
git_protocol: http
api_protocol: http
editor: /usr/bin/vim
check_update: false
display_hyperlinks: false
host: gitlab.${DOMAIN}:${LOAD_BALANCER_PORT}
api_host: gitlab.${DOMAIN}:${LOAD_BALANCER_PORT}
no_prompt: true
EOF

glab auth login -t ${PERSONAL_TOKEN} -h gitlab.${DOMAIN}:${LOAD_BALANCER_PORT}
glab auth status


echo -e "${BLUE}Creates repo folder${ENDCOLOR}"
git config --global user.email 'iwillens@student.42sp.org.br'
git config --global user.name 'iwillens'
rm -rf ./repo
mkdir -p ./repo
cp -r ../confs/deployments ./repo/
cd ./repo
git init

#creates repo on gitlab
echo -e "${BLUE}Creating Repo on Gitlab${ENDCOLOR}"
glab repo create -P root/${SRC_REPO_NAME}
git remote add origin http://root:${PERSONAL_TOKEN}@gitlab.${DOMAIN}:${LOAD_BALANCER_PORT}/root/${SRC_REPO_NAME}.git

#pushes file
git add ./deployments
git commit -m 'internal'
git push origin master

echo -e "${BLUE}Setting Up argocd for inspektor-internal...${ENDCOLOR}"

sg docker -c "
    kubectl delete namespace dev-internal
    kubectl create namespace dev-internal
    argocd app create inspektor-internal --repo http://gitlab-webservice-default.gitlab.svc:8181/root/${SRC_REPO_NAME}.git --path deployments --dest-server https://kubernetes.default.svc --sync-policy auto --dest-namespace gitlab-internal
"

#adds personal token to root user
echo -e "${BLUE}Remove SSH key if exists${ENDCOLOR}"
sg docker -c "
    kubectl exec $(kubectl get pods -l app=toolbox -n gitlab -o name) -ngitlab -ctoolbox -- gitlab-rails runner \"user=User.find_by_username('root'); user.keys.delete_all; user.save!\"
"
echo -e "${BLUE}Setting SSH key to root user${ENDCOLOR}"
sg docker -c "
    kubectl exec $(kubectl get pods -l app=toolbox -n gitlab -o name) -ngitlab -ctoolbox -- gitlab-rails runner \"user=User.find_by_username('root'); key=user.keys.create(id:1,title:'key',key:'${SSHKEY}');key;user.save!\"
"

#set gitlab-shell as node-port
echo -e "${BLUE}Expose port 22 to ${DOMAIN}...${ENDCOLOR}"
sg docker -c "
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: gitlab-gitlab-shell
  namespace: gitlab
spec:
  ports:
  - name: ssh
    port: 22
    nodePort: 32222
    protocol: TCP
    targetPort: 2222
  type: NodePort
EOF
"

echo -e "${BLUE}Cleaning up${ENDCOLOR}"
cd ..
rm -rf ./bin
rm -rf ./repo
rm -rf ${GLAB}

# Print ArgoCD credentials
echo -e "${BLUE}ArgoCD username:\n${RED}admin${ENDCOLOR}"
echo -e "${BLUE}ArgoCD password:${RED}"
sg docker -c "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
echo -e "${ENDCOLOR}"

#display password once again
echo -e "${BLUE}Gitlab username:\n${RED}root${ENDCOLOR}"
echo -e "${BLUE}Gitlab password:"
echo -e "${RED}${PASSWORD}${ENDCOLOR}"
echo

echo -e "${BLUE}Personal Token for user ${RED}root${ENDCOLOR}:"
echo -e "${RED}${PERSONAL_TOKEN}${ENDCOLOR}"
