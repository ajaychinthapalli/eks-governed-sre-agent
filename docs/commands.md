# Command reference: every EKS, AWS and kubectl command used

These are the commands used to build, deploy, debug and verify the agent on the dev cluster
`ac-ws-dev-use2` (us-east-2), in the order they were run.

- Account-specific values are shown as variables. The AWS account ID is masked as `111122223333`
  throughout this repo.
- Real output for the steps marked 📄 is in [`evidence/`](../evidence).

```bash
# Set once per shell
export CLUSTER=ac-ws-dev-use2
export REGION=us-east-2
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export MODEL=us.anthropic.claude-sonnet-4-5-20250929-v1:0
```

---

## 1. Connect to the existing cluster

```bash
aws eks update-kubeconfig --name $CLUSTER --region $REGION
kubectl config current-context
kubectl get ns
kubectl auth can-i '*' '*' --all-namespaces            # need cluster-admin to install
```

## 2. Check that the cluster is ready

```bash
# Version, VPC, endpoint access, control-plane logging
aws eks describe-cluster --name $CLUSTER --region $REGION \
  --query 'cluster.{version:version,vpc:resourcesVpcConfig.vpcId,privateApi:resourcesVpcConfig.endpointPrivateAccess,logs:logging.clusterLogging}'

# Add-ons: need eks-pod-identity-agent and vpc-cni (with network policy enabled)
aws eks list-addons --cluster-name $CLUSTER --region $REGION
aws eks describe-addon --cluster-name $CLUSTER --region $REGION --addon-name vpc-cni \
  --query 'addon.{version:addonVersion,config:configurationValues}'

# Nodes and instance types
kubectl get nodes -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone

# No conflicting CRDs from an earlier install
kubectl get crd | grep -E 'kagent|agentgateway|gateway.networking' || echo "none"

# Local CLIs
for b in kubectl aws helm jq python3 make git; do command -v $b >/dev/null && echo "ok $b" || echo "MISSING $b"; done
```

### 2a. EKS Pod Identity agent (how the gateway gets AWS credentials)

```bash
aws eks create-addon --cluster-name $CLUSTER --region $REGION --addon-name eks-pod-identity-agent
aws eks wait addon-active --cluster-name $CLUSTER --region $REGION --addon-name eks-pod-identity-agent
kubectl get ds -n kube-system eks-pod-identity-agent
```

### 2b. NetworkPolicy enforcement in the VPC CNI

```bash
aws eks update-addon --cluster-name $CLUSTER --region $REGION --addon-name vpc-cni \
  --configuration-values '{"enableNetworkPolicy":"true"}'
kubectl get ds -n kube-system aws-node -o jsonpath='{.spec.template.spec.containers[*].name}'; echo   # expect aws-eks-nodeagent
```

### 2c. Control-plane audit logs (where the executor's writes are recorded)

```bash
aws eks update-cluster-config --name $CLUSTER --region $REGION \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator"],"enabled":true}]}'
```

### 2d. Values the egress rules need

```bash
kubectl get endpoints kubernetes -n default                         # API server ENI IPs (in the VPC)
kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}'; echo
VPC=$(aws eks describe-cluster --name $CLUSTER --region $REGION --query cluster.resourcesVpcConfig.vpcId --output text)
aws ec2 describe-vpcs --vpc-ids $VPC --region $REGION --query 'Vpcs[0].CidrBlockAssociationSet[].CidrBlock'
aws ec2 describe-vpc-attribute --vpc-id $VPC --region $REGION --attribute enableDnsHostnames   # needed for a private Bedrock endpoint
```

### 2e. Bedrock model access

```bash
aws bedrock list-inference-profiles --region $REGION \
  --query "inferenceProfileSummaries[?contains(inferenceProfileId,'claude')].inferenceProfileId"

aws bedrock-runtime converse --region $REGION --model-id $MODEL \
  --messages '[{"role":"user","content":[{"text":"Reply with OK"}]}]' \
  --query 'output.message.content[0].text'                          # "OK"
```

### 2f. Default StorageClass (kagent's bundled Postgres needs a PVC) 📄 `03`

```bash
kubectl get storageclass
aws eks list-addons --cluster-name $CLUSTER --region $REGION | grep ebs || echo "no EBS CSI driver"

# EBS CSI driver add-on with its own Pod Identity role
cat > /tmp/pod-identity-trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},
  "Action":["sts:AssumeRole","sts:TagSession"]}]}
EOF
aws iam create-role --role-name $CLUSTER-ebs-csi --assume-role-policy-document file:///tmp/pod-identity-trust.json
aws iam attach-role-policy --role-name $CLUSTER-ebs-csi \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
aws eks create-addon --cluster-name $CLUSTER --region $REGION --addon-name aws-ebs-csi-driver \
  --pod-identity-associations serviceAccount=ebs-csi-controller-sa,roleArn=arn:aws:iam::$ACCOUNT:role/$CLUSTER-ebs-csi
aws eks wait addon-active --cluster-name $CLUSTER --region $REGION --addon-name aws-ebs-csi-driver
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver

# gp3 as the default StorageClass
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  type: gp3
  encrypted: "true"
EOF
kubectl get storageclass
```

### 2g. Node capacity (the platform needs about 19 pod slots and 2.3 GiB of memory)

```bash
# Pods per node vs. allowed (t3.small allows 11)
kubectl get nodes -o custom-columns=NODE:.metadata.name,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type,PODS:.status.allocatable.pods
kubectl get pods -A -o wide --field-selector=status.phase=Running --no-headers | awk '{print $8}' | sort | uniq -c
kubectl describe pod -n kagent -l app.kubernetes.io/component=controller | grep -A3 Events   # "Too many pods"

# The existing nodes were self-managed (CloudFormation), so there was no managed nodegroup to scale
aws eks list-nodegroups --cluster-name $CLUSTER --region $REGION

# Let new managed nodes and the existing self-managed nodes talk (both directions)
CLUSTER_SG=$(aws eks describe-cluster --name $CLUSTER --region $REGION --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)
NODE_SG=<security group of the self-managed nodes>
aws ec2 authorize-security-group-ingress --region $REGION --group-id $NODE_SG    --protocol -1 --source-group $CLUSTER_SG
aws ec2 authorize-security-group-ingress --region $REGION --group-id $CLUSTER_SG --protocol -1 --source-group $NODE_SG

# Managed nodegroup: 2 x t3.large (35 pods each), Amazon Linux 2023
aws eks create-nodegroup --cluster-name $CLUSTER --region $REGION --nodegroup-name ng-t3-large \
  --instance-types t3.large --ami-type AL2023_x86_64_STANDARD \
  --scaling-config minSize=2,maxSize=2,desiredSize=2 \
  --node-role <existing node instance role ARN> \
  --subnets <subnet-a> <subnet-b> <subnet-c>
aws eks wait nodegroup-active --cluster-name $CLUSTER --region $REGION --nodegroup-name ng-t3-large
kubectl get nodes -L node.kubernetes.io/instance-type
```

## 3. Configure, check, install 📄 `01`, `02`, `04`

```bash
vi envs/dev.env                     # context, cluster, region, account, model, namespaces
make configure ENV=dev              # renders deploy/dev/ (reads VPC CIDRs + API ClusterIP)
make preflight ENV=dev              # read-only; 0 blocking issues before install
make install ENV=dev
```

What `make install` runs in direct mode (see [`scripts/install.sh`](../scripts/install.sh)):

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml   # only if missing
helm upgrade --install agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds --version v1.5.0 -n agentgateway-system --create-namespace
helm upgrade --install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds --version 0.10.1 -n kagent --create-namespace
helm upgrade --install agentgateway oci://cr.agentgateway.dev/charts/agentgateway --version v1.5.0 -n agentgateway-system -f helm-values/agentgateway.yaml
kubectl label ns <platform namespaces> pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/audit=restricted
helm upgrade --install otel-collector opentelemetry-collector --repo https://open-telemetry.github.io/opentelemetry-helm-charts --version 0.174.0 -n sre-observability -f helm-values/otel-collector.yaml -f deploy/dev/values/otel-collector.yaml
helm upgrade --install kagent-tools    oci://ghcr.io/kagent-dev/tools/helm/kagent-tools --version 0.3.0 -n kagent-tools    -f helm-values/kagent-tools.yaml
helm upgrade --install kagent-executor oci://ghcr.io/kagent-dev/tools/helm/kagent-tools --version 0.3.0 -n kagent-executor -f helm-values/kagent-executor.yaml
helm upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent --version 0.10.1 -n kagent -f helm-values/kagent.yaml -f deploy/dev/values/kagent.yaml
kubectl apply --server-side -k deploy/dev/platform     # gateway, routes, policies, agent, RBAC, NetworkPolicies, admission
kubectl apply -k deploy/dev/demo                       # broken sample apps in sre-sandbox
ENV=dev scripts/aws-setup.sh                           # IAM role + Pod Identity association, restart proxy
```

What `scripts/aws-setup.sh` does with the AWS CLI:

```bash
aws iam create-role --role-name $CLUSTER-agentgateway-bedrock --assume-role-policy-document file://trust.json   # pods.eks.amazonaws.com
aws iam put-role-policy --role-name $CLUSTER-agentgateway-bedrock --policy-name $CLUSTER-agentgateway-bedrock-invoke \
  --policy-document file://perm.json            # bedrock:InvokeModel + InvokeModelWithResponseStream only
aws eks create-pod-identity-association --cluster-name $CLUSTER --region $REGION \
  --namespace agentgateway-system --service-account agentgateway-proxy \
  --role-arn arn:aws:iam::$ACCOUNT:role/$CLUSTER-agentgateway-bedrock
kubectl rollout restart deploy/agentgateway-proxy -n agentgateway-system   # repeated until every pod has credentials
```

## 4. Watch the install

```bash
kubectl get pods -n kagent -w
kubectl get events -n kagent --sort-by=.lastTimestamp | tail -20
kubectl logs -n kagent deploy/kagent-controller --tail=40
kubectl get pvc -n kagent
kubectl get pods -A | grep -E 'kagent|agentgateway|sre-'
helm list -A
```

## 5. Verify 📄 `05`, `07`

```bash
make verify ENV=dev                 # 60 checks against the live cluster
```

Useful one-off checks:

```bash
# The two tool servers and what kagent discovered
kubectl get remotemcpserver -n kagent k8s-diagnostics -o jsonpath='{.status.discoveredTools[*].name}'; echo
kubectl get remotemcpserver -n kagent k8s-remediation -o jsonpath='{.status.discoveredTools[*].name}'; echo
kubectl get agent -n kagent sre-triage-agent

# Gateway objects
kubectl get gateway,httproute -n agentgateway-system
kubectl get agentgatewaybackend,agentgatewaypolicy -n agentgateway-system

# Identity split
kubectl auth can-i patch deployments -n sre-sandbox --as system:serviceaccount:kagent-tools:kagent-tools        # no
kubectl auth can-i patch deployments -n sre-sandbox --as system:serviceaccount:kagent-executor:kagent-executor  # yes
kubectl auth can-i get pods/log      -n sre-sandbox --as system:serviceaccount:kagent-executor:kagent-executor  # no

# Remediation guard (server-side dry run as the executor)
kubectl set image deploy/frontend -n sre-sandbox web=public.ecr.aws/nginx/nginx:latest --dry-run=server \
  --as system:serviceaccount:kagent-executor:kagent-executor                                                    # denied
kubectl scale deploy/frontend -n sre-sandbox --replicas=50 --dry-run=server \
  --as system:serviceaccount:kagent-executor:kagent-executor                                                    # denied

# Admission policies and NetworkPolicies
kubectl get validatingadmissionpolicy,validatingadmissionpolicybinding | grep sre-
kubectl get networkpolicy -A | grep -E 'kagent|agentgateway|sre-'
kubectl get ns -L pod-security.kubernetes.io/enforce,pod-security.kubernetes.io/warn | grep -E 'kagent|agentgateway|sre-'
```

## 6. Debug the Bedrock 500 (one gateway pod without credentials) 📄 `06`

```bash
# Call the model through the gateway from inside the cluster
kubectl run bedrock-test -n kagent --rm -i --restart=Never --image=curlimages/curl -- \
  sh -c "sleep 8; curl -s -m 60 -w '\nHTTP %{http_code}\n' http://agentgateway-proxy.agentgateway-system.svc.cluster.local/v1/chat/completions \
  -H 'content-type: application/json' -d '{\"model\":\"any\",\"max_tokens\":10,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK\"}]}'"

# Which pod failed, and why
kubectl logs -n agentgateway-system -l gateway.networking.k8s.io/gateway-name=agentgateway-proxy --tail=300 --prefix \
  | grep -iE 'bedrock|credential|error|500|throttl|denied' | tail -20
kubectl get pods -n agentgateway-system -o wide
aws eks list-pod-identity-associations --cluster-name $CLUSTER --region $REGION --namespace agentgateway-system --output table

# Does every proxy pod have the Pod Identity env var?
for p in $(kubectl get pods -n agentgateway-system -l gateway.networking.k8s.io/gateway-name=agentgateway-proxy -o name); do
  echo "$p: $(kubectl get $p -n agentgateway-system -o jsonpath='{.spec.containers[0].env[*].name}' | tr ' ' '\n' | grep AWS_CONTAINER_CREDENTIALS_FULL_URI)"
done
kubectl rollout restart deploy/agentgateway-proxy -n agentgateway-system
kubectl rollout status  deploy/agentgateway-proxy -n agentgateway-system
```

## 7. Debug the 429 (LLM budget) 📄 `08`

```bash
kubectl logs -n agentgateway-system -l gateway.networking.k8s.io/gateway-name=agentgateway-proxy --tail=500 \
  | grep '"http.status":429' | grep -oE '"(reason|error)":"[^"]*"' | sort | uniq -c
# "reason":"RateLimit" = the gateway's own budget. ThrottlingException = Bedrock quota.

# Raise the budget: set LLM_TOKENS_PER_MINUTE / LLM_REQUESTS_PER_MINUTE in envs/dev.env, then
make configure ENV=dev
kubectl apply --server-side -k deploy/dev/platform
kubectl get agentgatewaypolicy llm-budget -n agentgateway-system -o jsonpath='{.spec.traffic.rateLimit.local}'; echo
```

## 8. Demo 📄 `09`

```bash
make demo ENV=dev
# kagent UI:        http://localhost:8082   (kubectl port-forward -n kagent svc/kagent-ui 8082:8080)
# agentgateway UI:  http://localhost:15000/ui/

# Scene 3: the credential-leak test
kubectl logs -n agentgateway-system -l gateway.networking.k8s.io/gateway-name=agentgateway-proxy --tail=300 | grep '"http.status":403'

# Scene 4: what the executor changed, from the EKS audit log (CloudWatch Logs Insights, /aws/eks/$CLUSTER/cluster)
#   fields @timestamp, verb, objectRef.resource, objectRef.name, responseStatus.code
#   | filter user.username = "system:serviceaccount:kagent-executor:kagent-executor" and verb in ["patch","update"]
kubectl logs -n sre-observability deploy/opentelemetry-collector | tail
```

## 9. Clean up

```bash
make clean ENV=dev     # Helm releases, namespaces, RoleBindings, admission policies, Pod Identity association, IAM role
# Cluster prerequisites added in step 2 (remove only if nothing else uses them):
aws eks delete-nodegroup --cluster-name $CLUSTER --region $REGION --nodegroup-name ng-t3-large
aws eks delete-addon     --cluster-name $CLUSTER --region $REGION --addon-name aws-ebs-csi-driver
```
