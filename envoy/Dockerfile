# Original from envoyproject/envoy:examples/front-proxy/Dockerfile-frontenvoy
FROM envoyproxy/envoy:v1.32-latest

WORKDIR /opt/envoy/

COPY ./start-gateway.sh ./envoy-gateway.yaml ./

CMD ["./start-gateway.sh"]
