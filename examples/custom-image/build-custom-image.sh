#!/bin/bash
set -x
# aws credentials
cloud_provider=$1
export PACKER_LOG=1
source ./custom-image-config
build_aws_ami() {
    packer init cloud/aws/config.pkr.hcl
    packer build --var-file=cloud/aws/ubuntu-2204.json cloud/aws/packer.json
}
# Not implemented yet
build_azure_vhd() {
    packer init cloud/azure/config.pkr.hcl
    packer build --var-file=cloud/azure/ubuntu-2204.json cloud/azure/packer.json
}

if [ "$cloud_provider" == "aws" ]; then
    export AWS_BUILD_ACCESS_KEY=${aws_access_key}
    export AWS_BUILD_SECRET_KEY=${aws_secret_key}
    build_aws_ami
elif [ "$cloud_provider" == "azure" ]; then
    export AZURE_BUILD_CLIENT_ID=${azure_client_id}
    export AZURE_BUILD_CLIENT_SECRET=${azure_client_secret}
    export AZURE_BUILD_TENANT_ID=${azure_tenant_id}
    export AZURE_BUILD_SUBSCRIPTION_ID=${azure_subscription_id}
    build_azure_vhd
fi