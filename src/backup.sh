#!/usr/bin/env bash

# Timestamp for backup
export FDATE=$(date '+%Y-%m-%d-%H-%M-%S')

# Create some temp folders
mkdir -p /tmp/kube-backup-${FDATE}/namespace
mkdir -p /root/.mc/share

# Global config 
export GLOBALRESOURCES=${GLOBALRESOURCES:-"storageclasses,networkpolicy,customresourcedefinition,clusterrolebinding,clusterrole"}
export RESOURCETYPES=${RESOURCETYPES:-"pvc,svc,ingress,configmap,secrets,ds,rc,deployment,statefulset,cronjob,serviceaccount,role,rolebinding"}
export TARFILENAME="kube-backup-${FDATE}.tar.gz"

# Required variables for container to work
REQUIRED=('S3_ALIAS', 'S3_ENDPOINT', 'S3_BUCKET', 'S3_ACCESS_KEY', 'S3_SECRET_KEY')

function dump_kubernetes_state() {
	echo "Dumping Namespaces" > /dev/stderr
	kubectl get --export -o=json ns | \
	jq '.items[] |
		select(.metadata.name!="kube-system") |
		select(.metadata.name!="kube-public") |
		select(.metadata.name!="kubernetes") |
		del(.status,
	        .metadata.uid,
	        .metadata.selfLink,
	        .metadata.resourceVersion,
	        .metadata.creationTimestamp,
	        .metadata.generation
	    )' > /tmp/kube-backup-${FDATE}/namespaces-dump.json

	# dump global resources state
	for resource in ${GLOBALRESOURCES}; do
	  echo "Dumping global resources: ${resource}" > /dev/stderr
	  kubectl get --export -o=json ${resource} | \
	  jq --sort-keys \
	      'del(
	          .items[].metadata.annotations."kubectl.kubernetes.io/last-applied-configuration",
	          .items[].metadata.uid,
	          .items[].metadata.selfLink,
	          .items[].metadata.resourceVersion,
	          .items[].metadata.creationTimestamp,
	          .items[].metadata.generation
	      )' > /tmp/kube-backup-${FDATE}/global-resources-dump.json
	done

	# Save namespace resources
	echo "Dumping resources by namespace" > /dev/stderr
	for namespace in $(jq -r '.metadata.name' < /tmp/kube-backup-${FDATE}/namespaces-dump.json);do
	    echo "  ${namespace}" > /dev/stderr
	    kubectl --namespace="${namespace}" get --export -o=json ${RESOURCETYPES} | \
	    jq '.items[] |
	        select(.type!="kubernetes.io/service-account-token") |
	        del(
	            .spec.clusterIP,
	            .metadata.uid,
	            .metadata.selfLink,
	            .metadata.resourceVersion,
	            .metadata.creationTimestamp,
	            .metadata.generation,
	            .status,
	            .spec.template.spec.securityContext,
	            .spec.template.spec.dnsPolicy,
	            .spec.template.spec.terminationGracePeriodSeconds,
	            .spec.template.spec.restartPolicy
	        )' > /tmp/kube-backup-${FDATE}/namespace/${namespace}.json
	done
}

function compress_backup() {
	tar czf /tmp/${TARFILENAME} -C /tmp kube-backup-${FDATE}
}

# Check so all required params are set
for REQ in "${REQUIRED[@]}"; do
	if [ -z "$(eval echo \$$REQ)" ]; then
		echo "Missing required config value: ${REQ}"
		exit 1
	fi
done

# Setup Minio client
function setup_s3() {
	# This outputs less in the logs that using 'mc host config'
	cat > /root/.mc/config.json <<EOF
{
	"version": "8",
	"hosts": {
		"${S3_ALIAS}": {
			"url": "${S3_ENDPOINT}",
			"accessKey": "${S3_ACCESS_KEY}",
			"secretKey": "${S3_SECRET_KEY}",
			"api": "S3v4"
		}
	}
}
EOF
	tee /root/.mc/share/downloads.json > /root/.mc/share/uploads.json <<EOF
{
	"version": "1",
	"shares": {}
}
EOF
	# Setup bucket if it doesn't exist
	if mc ls ${S3_ALIAS}/${S3_BUCKET} 2>&1 | grep -qE "Bucket(.*)does not exist.$"
	then
		echo "${S3_BUCKET} does not exist, creating it"
		mc mb ${S3_ALIAS}/${S3_BUCKET}
	fi
}

# Setup Minio s3 client
setup_s3

# Dump kubernetes logical state
dump_kubernetes_state

# Compress the backups to save some storage
compress_backup

# Transfer backups to S3 storage & remove it before pod shutdown as pods are not deleted directly but scheduled for GC
mc cp /tmp/${TARFILENAME} ${S3_ALIAS}/${S3_BUCKET} --no-color
rm -rf /tmp

echo "Backup Done ✓"
