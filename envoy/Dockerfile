# Original from envoyproject/envoy:examples/front-proxy/Dockerfile-frontenvoy
#
# Do not use "-latest" versions because those are not updated without always pull policy
FROM envoyproxy/envoy:v1.39.1

USER root

# Install debugging software packages
ENV DEBIAN_FRONTEND=noninteractive
RUN set -x \
  && apt-get update -y \
  && apt-get install --no-install-recommends --no-install-suggests -y \
    wget curl iproute2 iputils-ping netcat-openbsd less vim

USER envoy

WORKDIR /opt/envoy/

COPY ./start-gateway.sh ./envoy-gateway.yaml ./

CMD ["./start-gateway.sh"]
