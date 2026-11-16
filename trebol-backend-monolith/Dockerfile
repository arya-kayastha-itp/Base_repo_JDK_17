# Trebol backend API image. Build context: this folder (trebol-backend-monolith).
#   docker build -t trebol-api:local .
# Runs as a non-root user on port 8080. Nothing environment-specific is baked in: without environment
# variables the app starts on its in-memory H2 database; with SPRING_PROFILES_ACTIVE=azure and the
# database/JWT variables it uses MySQL (see docs/01-analysis.md, section 7).

ARG BUILD_IMAGE=maven:3.9.16-eclipse-temurin-17
ARG RUNTIME_IMAGE=eclipse-temurin:17.0.21_9-jre-alpine

########## Stage 1: build the executable WAR ##########
FROM ${BUILD_IMAGE} AS build
WORKDIR /workspace
# Optional extra Maven flags, e.g. one-at-a-time downloads on networks where parallel downloads stall:
#   --build-arg MAVEN_EXTRA_ARGS="-Daether.dependencyCollector.bf.threads=1 -Daether.connector.basic.threads=1"
ARG MAVEN_EXTRA_ARGS=""
# Azure Application Insights Java agent (telemetry without code changes). Downloaded through Maven (checksums of
# Maven Central) and pinned by SHA-256. It is NOT loaded by default: in Azure the app sets
# JDK_JAVA_OPTIONS=-javaagent:/app/applicationinsights-agent.jar plus the connection string. This step comes before
# the sources, so it stays cached across code changes.
ARG AI_AGENT_VERSION=3.7.10
ARG AI_AGENT_SHA256=93a70c8f5d364c7e777f6c4d1b235dba91aef8448bd3fa94359f1d7f3e2eb0ec
RUN --mount=type=cache,target=/root/.m2 mvn -B -ntp ${MAVEN_EXTRA_ARGS} \
      org.apache.maven.plugins:maven-dependency-plugin:3.11.0:copy \
      -Dartifact=com.microsoft.azure:applicationinsights-agent:${AI_AGENT_VERSION} \
      -DoutputDirectory=/workspace/agent -Dmdep.stripVersion=true \
 && echo "${AI_AGENT_SHA256}  /workspace/agent/applicationinsights-agent.jar" | sha256sum -c -
COPY pom.xml .
COPY src ./src
# Maven's download cache is a BuildKit cache mount: it is kept between builds (and between attempts after a
# network failure) without ending up in any image layer.
# Tests do not run here: 'mvn verify' runs them before the image is built (locally and in the pipeline).
RUN --mount=type=cache,target=/root/.m2 mvn -B -ntp ${MAVEN_EXTRA_ARGS} -DskipTests package

########## Stage 2: split the WAR into its layers ##########
FROM ${RUNTIME_IMAGE} AS extract
WORKDIR /extract
COPY --from=build /workspace/target/*.war app.war
RUN java -Djarmode=tools -jar app.war extract --layers --launcher --destination layers

########## Stage 3: runtime ##########
FROM ${RUNTIME_IMAGE}
# Non-root user with a fixed numeric id (Kubernetes 'runAsNonRoot' checks need a number)
RUN addgroup -S -g 10001 trebol && adduser -S -D -H -u 10001 -G trebol trebol
WORKDIR /app
# Monitoring agent, loaded only when JDK_JAVA_OPTIONS names it (see the build stage)
COPY --from=build /workspace/agent/applicationinsights-agent.jar ./applicationinsights-agent.jar
# One Docker layer per WAR layer, least frequently changed first: a code change only rebuilds the last one.
# The files stay owned by root, so the application cannot modify its own code.
COPY --from=extract /extract/layers/dependencies/ ./
COPY --from=extract /extract/layers/spring-boot-loader/ ./
COPY --from=extract /extract/layers/snapshot-dependencies/ ./
COPY --from=extract /extract/layers/application/ ./
USER 10001:10001
EXPOSE 8080
# Heap = 75% of the container's memory; exit on OutOfMemoryError so the platform restarts the container;
# UTF-8 whatever the base image's locale. The whole value can be replaced at run time through this variable.
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError -Dfile.encoding=UTF-8"
# Exec form: Java is the container's main process and receives the platform's stop signal (SIGTERM)
# directly, which graceful shutdown needs. A shell-form ENTRYPOINT would put /bin/sh in between.
ENTRYPOINT ["java", "org.springframework.boot.loader.launch.WarLauncher"]
