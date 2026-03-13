FROM eclipse-temurin:11-jdk-jammy AS envoy-tracing-server-app-build

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
  && apt-get install --no-install-recommends --no-install-suggests -y \
    wget \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/server-app/

COPY . .
RUN ./mvnw clean package

#
# Do not use "-latest" versions because those are not updated without always pull policy
FROM envoyproxy/envoy:v1.37.0

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends --no-install-suggests \
      openjdk-11-jre \
      tzdata \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

VOLUME /tmp
WORKDIR /opt/server-app/

ARG jar_file=target/server-app-1.0.0.RELEASE.jar
COPY --from=envoy-tracing-server-app-build /opt/server-app/${jar_file} ./app.jar

COPY ./start-server-app.sh ./envoy-server-app.yaml ./
ENTRYPOINT ["./start-server-app.sh"]

CMD ["java","-jar","app.jar"]
