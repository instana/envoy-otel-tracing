# Original from envoyproject/envoy:examples/front-proxy/Dockerfile-frontenvoy
#
# Do not use "-latest" versions because those are not updated without always pull policy
FROM envoyproxy/envoy:v1.36.2

WORKDIR /opt/envoy/

COPY ./start-gateway.sh ./envoy-gateway.yaml ./

CMD ["./start-gateway.sh"]
