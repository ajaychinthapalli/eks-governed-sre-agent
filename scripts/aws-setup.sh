#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # ok/warn always return 0; JMESPath backticks are literal
# AWS resources for ONE environment, with the AWS CLI. Idempotent: safe to run again.
#   ENV=prod scripts/aws-setup.sh            (scripts/install.sh calls it)
#
#   1. BEDROCK_PRIVATE_ENDPOINT=true: an interface VPC endpoint for bedrock-runtime (and sts for
#      IRSA) with private DNS, so Bedrock traffic never leaves the VPC. An existing endpoint in the
#      VPC is reused; one created here is tagged sre-agent/cluster=<cluster> so cleanup removes it.
#   2. IAM role for the gateway: bedrock:InvokeModel* only. With a private endpoint, the policy
#      also requires aws:SourceVpce = that endpoint, so the credentials are useless anywhere else.
#   3. Bind the role to the gateway's ServiceAccount (EKS Pod Identity association, or IRSA trust).
source "$(dirname "$0")/lib.sh"
need aws jq

SA=$(proxy_service_account)
[[ -n "${SA}" ]] || die "agentgateway proxy not deployed yet (deploy/${GATEWAY_NAME} in ${AGW_NS})"
ROLE="${GATEWAY_IAM_ROLE_NAME}"
TAG_KEY="sre-agent/cluster"
WORK=$(mktemp -d); trap 'rm -rf "${WORK}"' EXIT
CLUSTER_JSON=$(awsr eks describe-cluster --name "${CLUSTER_NAME}" --output json)
VPC_ID=$(jq -r .cluster.resourcesVpcConfig.vpcId <<<"${CLUSTER_JSON}")
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[[ "${ACCOUNT}" == "${AWS_ACCOUNT_ID}" ]] || die "AWS credentials are for account ${ACCOUNT}, envs/${ENV_NAME}.env says ${AWS_ACCOUNT_ID}"

# ---------------------------------------------------------------- 1. VPC endpoints
ensure_endpoint() {  # ensure_endpoint <service short name>  -> prints the endpoint id
  local svc="com.amazonaws.${AWS_REGION}.$1" id
  id=$(awsr ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=${svc}" \
        "Name=vpc-endpoint-state,Values=available,pending" --query 'VpcEndpoints[0].VpcEndpointId' --output text)
  if [[ -n "${id}" && "${id}" != None ]]; then
    local dns
    dns=$(awsr ec2 describe-vpc-endpoints --vpc-endpoint-ids "${id}" --query 'VpcEndpoints[0].PrivateDnsEnabled' --output text)
    [[ "${dns}" == True ]] && ok "reusing ${svc} endpoint ${id} (private DNS on)" >&2 \
      || warn "reusing ${svc} endpoint ${id}, but its private DNS is OFF: pods will resolve the public name and egress lockdown will block it" >&2
    echo "${id}"; return
  fi
  # one subnet per AZ, private subnets first (the cluster's own subnets)
  local subnets cluster_subnets
  cluster_subnets=$(jq -r '.cluster.resourcesVpcConfig.subnetIds | join(" ")' <<<"${CLUSTER_JSON}")
  # shellcheck disable=SC2086  # word splitting of the subnet list is intended
  subnets=$(awsr ec2 describe-subnets --subnet-ids ${cluster_subnets} \
    --query 'Subnets[].[AvailabilityZone,MapPublicIpOnLaunch,SubnetId]' --output text \
    | sort -k1,1 -k2,2 | awk '!seen[$1]++ {print $3}' | tr '\n' ' ')
  local sg
  sg=$(awsr ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${CLUSTER_NAME}-sre-agent-endpoints" \
        --query 'SecurityGroups[0].GroupId' --output text)
  if [[ -z "${sg}" || "${sg}" == None ]]; then
    sg=$(awsr ec2 create-security-group --vpc-id "${VPC_ID}" --group-name "${CLUSTER_NAME}-sre-agent-endpoints" \
          --description "HTTPS from the VPC to the SRE agent's interface endpoints" \
          --tag-specifications "ResourceType=security-group,Tags=[{Key=${TAG_KEY},Value=${CLUSTER_NAME}}]" --query GroupId --output text)
    local cidr
    for cidr in $(awsr ec2 describe-vpcs --vpc-ids "${VPC_ID}" \
                  --query 'Vpcs[0].CidrBlockAssociationSet[?CidrBlockState.State==`associated`].CidrBlock' --output text); do
      awsr ec2 authorize-security-group-ingress --group-id "${sg}" --protocol tcp --port 443 --cidr "${cidr}" >/dev/null
    done
    ok "security group ${sg} (443 from the VPC)" >&2
  fi
  # shellcheck disable=SC2086  # word splitting of the subnet list is intended
  id=$(awsr ec2 create-vpc-endpoint --vpc-id "${VPC_ID}" --vpc-endpoint-type Interface --service-name "${svc}" \
        --subnet-ids ${subnets} --security-group-ids "${sg}" --private-dns-enabled \
        --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=${TAG_KEY},Value=${CLUSTER_NAME}},{Key=Name,Value=${CLUSTER_NAME}-sre-agent-$1}]" \
        --query VpcEndpoint.VpcEndpointId --output text)
  ok "created ${svc} endpoint ${id} in subnets ${subnets}" >&2
  local end=$((SECONDS + 600))
  until [[ "$(awsr ec2 describe-vpc-endpoints --vpc-endpoint-ids "${id}" --query 'VpcEndpoints[0].State' --output text)" == available ]]; do
    (( SECONDS >= end )) && die "endpoint ${id} not available after 10 minutes"
    sleep 15
  done
  ok "endpoint ${id} available" >&2
  echo "${id}"
}

VPCE=""
if [[ "${BEDROCK_PRIVATE_ENDPOINT}" == true ]]; then
  log "VPC endpoints in ${VPC_ID}"
  [[ "$(awsr ec2 describe-vpc-attribute --vpc-id "${VPC_ID}" --attribute enableDnsHostnames --query EnableDnsHostnames.Value --output text)" == True ]] \
    || die "VPC ${VPC_ID} has enableDnsHostnames off: private DNS for endpoints needs it (aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-hostnames)"
  VPCE=$(ensure_endpoint bedrock-runtime)
  [[ "${AWS_AUTH_MODE}" == irsa ]] && ensure_endpoint sts >/dev/null
fi

# ---------------------------------------------------------------- 2. IAM role
log "IAM role ${ROLE} (${AWS_AUTH_MODE}) for ${AGW_NS}/${SA}"
if [[ "${AWS_AUTH_MODE}" == "pod-identity" ]]; then
  CLUSTER_ARN=$(jq -r .cluster.arn <<<"${CLUSTER_JSON}")
  cat > "${WORK}/trust.json" <<EOF
{ "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow",
    "Principal": { "Service": "pods.eks.amazonaws.com" },
    "Action": ["sts:AssumeRole", "sts:TagSession"],
    "Condition": {
      "StringEquals": { "aws:SourceAccount": "${AWS_ACCOUNT_ID}" },
      "ArnEquals":    { "aws:SourceArn": "${CLUSTER_ARN}" } } }] }
EOF
else
  OIDC=$(jq -r '.cluster.identity.oidc.issuer' <<<"${CLUSTER_JSON}" | sed 's|https://||')
  cat > "${WORK}/trust.json" <<EOF
{ "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": { "StringEquals": {
      "${OIDC}:aud": "sts.amazonaws.com",
      "${OIDC}:sub": "system:serviceaccount:${AGW_NS}:${SA}" } } }] }
EOF
fi
if aws iam get-role --role-name "${ROLE}" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "${ROLE}" --policy-document "file://${WORK}/trust.json"
  ok "role exists; trust policy updated"
else
  aws iam create-role --role-name "${ROLE}" --assume-role-policy-document "file://${WORK}/trust.json" \
    --description "agentgateway proxy on ${CLUSTER_NAME}: invoke Bedrock" --max-session-duration 3600 \
    --tags "Key=${TAG_KEY},Value=${CLUSTER_NAME}" >/dev/null
  ok "role created"
fi
COND=""
[[ -n "${VPCE}" ]] && COND=", \"Condition\": { \"StringEquals\": { \"aws:SourceVpce\": \"${VPCE}\" } }"
cat > "${WORK}/perm.json" <<EOF
{ "Version": "2012-10-17",
  "Statement": [{ "Sid": "InvokeBedrockModels", "Effect": "Allow",
    "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
    "Resource": ["arn:aws:bedrock:*::foundation-model/*",
                 "arn:aws:bedrock:*:${AWS_ACCOUNT_ID}:inference-profile/*"]${COND} }] }
EOF
aws iam put-role-policy --role-name "${ROLE}" --policy-name "${ROLE}-invoke" --policy-document "file://${WORK}/perm.json"
ok "permissions: bedrock:InvokeModel, InvokeModelWithResponseStream$([[ -n "${VPCE}" ]] && echo ", only through ${VPCE}")"
ROLE_ARN=$(aws iam get-role --role-name "${ROLE}" --query Role.Arn --output text)

# ---------------------------------------------------------------- 3. bind to the ServiceAccount
log "Bind role to ${AGW_NS}/${SA}"
if [[ "${AWS_AUTH_MODE}" == "pod-identity" ]]; then
  EXISTING=$(awsr eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" \
      --namespace "${AGW_NS}" --service-account "${SA}" --query 'associations[0].associationId' --output text)
  if [[ -z "${EXISTING}" || "${EXISTING}" == "None" ]]; then
    awsr eks create-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
      --namespace "${AGW_NS}" --service-account "${SA}" --role-arn "${ROLE_ARN}" \
      --tags "${TAG_KEY}=${CLUSTER_NAME}" >/dev/null
    ok "pod identity association created"
  else
    awsr eks update-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
      --association-id "${EXISTING}" --role-arn "${ROLE_ARN}" >/dev/null
    ok "pod identity association updated"
  fi
else
  grep -q "${ROLE_ARN}" "${DEPLOY_DIR}/platform/kustomization.yaml" \
    && ok "IRSA: deploy/${ENV_NAME}/platform annotates the ServiceAccount with ${ROLE_ARN}" \
    || warn "IRSA: run make configure ENV=${ENV_NAME} (and push) so the ServiceAccount carries ${ROLE_ARN}"
fi

log "Restart the proxy to pick up credentials"
# EKS injects the credential env vars only when a pod is created, and a brand-new association can
# take a little while to reach the injecting webhook: a pod created in that window starts without
# credentials (Bedrock calls then fail with "credential provider was not enabled"). So: restart,
# check EVERY proxy pod, and restart again until all of them carry credentials.
if [[ "${AWS_AUTH_MODE}" == "pod-identity" ]]; then CRED_VAR=AWS_CONTAINER_CREDENTIALS_FULL_URI; else CRED_VAR=AWS_WEB_IDENTITY_TOKEN_FILE; fi
pods_missing_creds() {
  k get pods -n "${AGW_NS}" -l gateway.networking.k8s.io/gateway-name="${GATEWAY_NAME}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[0].env[*].name}{"\n"}{end}' \
    | grep -v " .*${CRED_VAR}" | awk 'NF{print $1}' || true
}
sleep 20
for attempt in 1 2 3 4; do
  k rollout restart deploy/"${GATEWAY_NAME}" -n "${AGW_NS}" >/dev/null
  k rollout status deploy/"${GATEWAY_NAME}" -n "${AGW_NS}" --timeout=300s >/dev/null
  sleep 5
  MISSING=$(pods_missing_creds)
  [[ -z "${MISSING}" ]] && { ok "every proxy pod has AWS credentials (${CRED_VAR})"; break; }
  [[ ${attempt} == 4 ]] && die "proxy pods still without AWS credentials after 4 restarts: ${MISSING//$'\n'/ }. Check: aws eks list-pod-identity-associations --cluster-name ${CLUSTER_NAME} --region ${AWS_REGION}"
  warn "pods started without credentials (${MISSING//$'\n'/ }); waiting for the association to propagate, then restarting again"
  sleep 30
done
