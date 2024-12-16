# Create Custom Image on Public Cloud

This script automates the creation of a custom image on a public cloud provider (e.g., AWS). The script reads configuration values, manages required credentials, and invokes appropriate cloud-specific build commands.

## Prerequisites

1. **Dependencies**
   - Bash (Unix/Linux environment)
   - Packer CLI (https://developer.hashicorp.com/packer/install?product_intent=packer)

2. **Access and Credentials**
   - Ensure valid credentials for your target cloud provider.
   - For AWS, configure the `aws_access_key` and `aws_secret_key` in the configuration file i.e. custom-image-config.
   - Permissions to create and manage images for the chosen cloud provider.

3. **Configuration File**
    - **Global Configuration (`custom-image-config`)**:
     Contains details about the cloud provider's credentials.
   - **Cloud-Specific Configuration (`<cloud-provider>/<os-version>.json`)**:
     Specifies the instance details for the cloud provider.

## Usage

1. Prepare the Configuration Files:
    Create the custom-image-config file in the project root directory with the required credentials.
    Add the appropriate cloud-specific configuration file in the <cloud-provider>/ directory

2. Run the Build Script: Execute the build-custom-image.sh script with the desired cloud provider:
    ```bash
    cd examples/custom-image
    ./build-custom-image.sh <cloud provider>

    eg: ./build-custom-image.sh aws
