#!/bin/bash
#
# This script builds a Minio container image with specified Hugging Face
# models pre-downloaded and pushes it to a container registry.
#
# It uses podman for all container operations.
#
# Usage: ./build_model_image.sh <model_names> <full_image_name:tag>
#
# Example:
# ./build_model_image.sh "Qwen/Qwen2.5-0.5B-Instruct,meta-llama/Llama-2-7b-chat-hf" "quay.io/my_user/my-llms-minio:latest"
#

# Exit immediately if a command exits with a non-zero status.
set -eo pipefail

# --- Parameter Validation ---
if [ "$#" -ne 2 ]; then
    echo "Error: Invalid number of arguments."
    echo "Usage: $0 <model_names> <full_image_name:tag>"
    echo "Example: $0 \"model1,model2,model3\" \"quay.io/my_org/my-models-minio:v1\""
    exit 1
fi

MODEL_NAMES="$1"
FULL_IMAGE_NAME="$2"

# Parse the comma-separated model names into an array
IFS=',' read -ra MODEL_ARRAY <<< "$MODEL_NAMES"

# --- Configuration and Initial Confirmation ---
echo "--- Configuration ---"
echo "Hugging Face Models:"
for model in "${MODEL_ARRAY[@]}"; do
    echo "  - ${model}"
done
echo "Full Image Name:      ${FULL_IMAGE_NAME}"
echo "---------------------"
echo
read -p "Do you want to continue with this configuration? (y/N) " confirm
if [[ "${confirm}" != "y" || "${confirm}" != "Y" ]]; then
    echo "Aborted by user."
    exit 0
fi
echo

# --- Dockerfile Generation ---
echo "-> Generating dynamic Dockerfile..."
cat <<EOF > Dockerfile
# Stage 1: Downloader
# Uses a bootstrap image containing Python and huggingface-cli
FROM quay.io/trustyai_testing/llm-downloader-bootstrap@sha256:d3211cc581fe69ca9a1cb75f84e5d08cacd1854cb2d63591439910323b0cbb57 AS downloader

# Create the target directory within the build stage
RUN mkdir -p /tmp/models/llms

# Download all models
EOF

# Add download commands for each model
for model in "${MODEL_ARRAY[@]}"; do
    echo "RUN echo \"Downloading model: ${model}\" && \\" >> Dockerfile
    echo "    /tmp/venv/bin/huggingface-cli download ${model} --local-dir /tmp/models/llms/\$(basename ${model})" >> Dockerfile
done

cat <<EOF >> Dockerfile

# Stage 2: Final Image
# Uses the Minio base image for serving
FROM quay.io/trustyai_testing/modelmesh-minio-examples@sha256:d2ccbe92abf9aa5085b594b2cae6c65de2bf06306c30ff5207956eb949bb49da

# Copy the downloaded models from the downloader stage into the final image.
COPY --from=downloader /tmp/models/llms/ /data1/llms/
RUN chmod -R 777 /data1/llms

# Add labels to the image to identify the models it contains
EOF

# Add labels for each model
for model in "${MODEL_ARRAY[@]}"; do
    echo "LABEL \"huggingface.model.${model//\//.}\"=\"${model}\"" >> Dockerfile
done

echo "Dockerfile generated successfully."
echo

# --- Build Image ---
echo "-> Building container image: ${FULL_IMAGE_NAME}"
podman build -t "${FULL_IMAGE_NAME}" .
echo "Build complete."
echo

# --- Sanity Check ---
echo "-> Performing sanity check on the built image..."
# Check that all expected model folders exist
for model in "${MODEL_ARRAY[@]}"; do
    EXPECTED_MODEL_FOLDER=$(basename "$model")
    
    # We run a temporary container to list the contents of the expected model directory.
    # If the directory or its contents don't exist, the 'ls' command will fail,
    # returning a non-zero exit code, which will be caught by the 'if !' statement.
    # Output is redirected to /dev/null as we only care about the success/failure.
    if ! podman run --rm --entrypoint /bin/ls "${FULL_IMAGE_NAME}" "/data1/llms/${EXPECTED_MODEL_FOLDER}" &> /dev/null; then
        echo "Error: Sanity check FAILED."
        echo "      The model folder '${EXPECTED_MODEL_FOLDER}' was not found in '/data1/llms/' inside the image."
        echo "      The image '${FULL_IMAGE_NAME}' was built but may be invalid."
        rm Dockerfile # Cleanup
        exit 1
    fi
    echo "✓ Model folder '${EXPECTED_MODEL_FOLDER}' found inside the image."
done
echo "Sanity check PASSED: All model folders found inside the image."
echo

# --- Push Confirmation ---
echo "Image built and verified successfully."
read -p "Push to registry? Registry: ${FULL_IMAGE_NAME}. Confirmation: (y/N) " push_confirm
if [[ "${push_confirm,,}" != "y" ]]; then
    echo "Push aborted by user."
    echo "The local image '${FULL_IMAGE_NAME}' is available for inspection."
    rm Dockerfile # Cleanup
    exit 0
fi
echo

# --- Push Image ---
echo "-> Pushing image with podman..."
echo "   (This assumes you are already logged in via 'podman login quay.io')"
# The 'set -e' command will cause the script to exit on failure.
podman push "${FULL_IMAGE_NAME}"
echo "Push complete."
echo

# --- Cleanup ---
echo "-> Cleaning up temporary Dockerfile..."
rm Dockerfile
echo

echo "✅ Success! Image has been built and pushed to:"
echo "${FULL_IMAGE_NAME}"