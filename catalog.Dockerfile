ARG OPM_IMAGE=quay.io/operator-framework/opm:latest
# OPM image to use:
# For <= 4.14, use registry.redhat.io/openshift4/ose-operator-registry:v4.yy
# For >= 4.15, use registry.redhat.io/openshift4/ose-operator-registry-rhel9:v4.yy

# Note: for a time we needed to get images from brew for pre-release OCP
# versions - ATM this is not needed, but in case this is needed
# in the future, the format was like this:
# brew.registry.redhat.io/rh-osbs/openshift-ose-operator-registry-rhel9:v4.21

# The builder image is expected to contain /bin/opm (with serve subcommand)
FROM ${OPM_IMAGE} as builder

# Copy specified FBC catalog into image at /configs and pre-populate serve cache
ARG INPUT_DIR
COPY ./${INPUT_DIR}/ /configs/volsync-product
RUN ["/bin/opm", "serve", "/configs", "--cache-dir=/tmp/cache", "--cache-only"]

# The base image is expected to contain /bin/opm (with serve subcommand) and /bin/grpc_health_probe
FROM ${OPM_IMAGE}

COPY --from=builder /configs /configs
COPY --from=builder /tmp/cache /tmp/cache

# Set FBC-specific label for the location of the FBC root directory in the image
LABEL operators.operatorframework.io.index.configs.v1=/configs
LABEL operators.operatorframework.io.bundle.mediatype.v1=registry+v1
LABEL operators.operatorframework.io.bundle.manifests.v1=manifests/
LABEL operators.operatorframework.io.bundle.metadata.v1=metadata/
LABEL operators.operatorframework.io.bundle.package.v1=volsync-product
LABEL operators.operatorframework.io.bundle.channels.v1=alpha
LABEL operators.operatorframework.io.metrics.builder=operator-sdk-v1.33.1
LABEL operators.operatorframework.io.metrics.mediatype.v1=metrics+v1
LABEL operators.operatorframework.io.metrics.project_layout=go.kubebuilder.io/v3

ENTRYPOINT ["/bin/opm"]
CMD ["serve", "/configs", "--cache-dir=/tmp/cache"]
