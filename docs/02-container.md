# Trébol backend: container image

This document is the container deliverable of the POC (Requirement 2). It explains how the API is packaged as a
container image, the design choices behind the Dockerfile and the local docker-compose stack, how to build, run
and verify them, and the result of the vulnerability scan. Everything below was verified on 12 Nov 2026 with the
image built from commit `b393abe` (Spring Boot 3.5.16) and the scan exceptions of commit `8b9ec99`.

## 1. Requirement checklist

| Requirement | How it is met | Evidence |
|---|---|---|
| Multi-stage Dockerfile | Three stages: build (Maven + JDK), extract (WAR layers), runtime (JRE only) | `trebol-backend-monolith/Dockerfile` |
| Slim base image | Eclipse Temurin 17 **JRE** on Alpine 3.24 (68 MB) | Final image about 139 MB; since Phase 5 plus the 46 MB monitoring agent (section 3) |
| Non-root user | Fixed user and group id 10001; application files owned by root and read-only for the app | `id` in the container: `uid=10001`; writing to `/app`: `Permission denied` |
| Only the required port | `EXPOSE 8080` only | `docker image inspect` |
| Configuration through environment variables | No profile, URL or secret in the image: H2 by default, profile `azure` through environment variables | [01-analysis.md, section 7](01-analysis.md#7-configuration) |
| docker-compose for dependencies | `compose.yaml`: API + MySQL 8.4 | Smoke test 45/45 |
| `docker build` / `docker run` work locally | Yes | Smoke test 45/45 against the container |
| No critical CVEs | Trivy gate: **0 critical**; 2 findings accepted with written reasons and an expiry date | Section 7 |

## 2. Files

| File | Purpose |
|---|---|
| `trebol-backend-monolith/Dockerfile` | Image definition |
| `trebol-backend-monolith/.dockerignore` | Build context allow-list: only `pom.xml` and `src/` are sent to Docker |
| `compose.yaml` | Local stack: API (profile `azure`) + MySQL 8.4 |
| `.env.example` | Template for the compose values; the real `.env` is git-ignored |
| `.trivyignore.yaml` | Accepted scan findings, each with package version, reason and expiry date |

## 3. Dockerfile design

| Stage | Base image | What happens |
|---|---|---|
| `build` | `maven:3.9.16-eclipse-temurin-17` | Copies `pom.xml` and `src/`, runs `mvn package -DskipTests` with Maven's download cache in a BuildKit cache mount |
| `extract` | `eclipse-temurin:17.0.21_9-jre-alpine` | Splits the executable WAR into its Spring Boot layers (`-Djarmode=tools extract --layers --launcher`) |
| runtime | `eclipse-temurin:17.0.21_9-jre-alpine` | Creates user 10001, copies the four layers, exposes 8080, starts `WarLauncher` |

| Choice | Why | Alternative considered |
|---|---|---|
| Temurin 17 JRE on Alpine | Small, only a Java runtime (no compiler), few OS packages: the scan finds 1 OS-level finding. Keeps a shell for debugging | Distroless (smaller, but no shell at all); Ubuntu-based Temurin (larger, more OS CVEs) |
| Exact version tags | Reproducible builds; base image updates become deliberate, reviewable changes | Floating tags such as `17-jre-alpine` |
| Multi-stage build | Maven, the JDK and the sources never reach the runtime image | Copying a WAR built outside Docker |
| Tests not run in the image build | `mvn verify` runs the 372 tests before the image is built (locally and in the pipeline); image builds stay fast | Running tests inside `docker build` |
| BuildKit cache mount for `~/.m2` | Dependencies are kept between builds, and an interrupted download resumes instead of starting again; nothing of it ends up in an image layer | `dependency:go-offline` in its own layer (downloads more than needed and restarts from zero after a failure) |
| One Docker layer per Spring Boot layer, least frequently changed first | A code change only rebuilds and pushes the application layer (2.1 MB) instead of the whole application | Copying the WAR as one 70 MB layer |
| Fixed numeric user 10001, files owned by root | Least privilege: the process cannot change its own code. A numeric id is required by Kubernetes `runAsNonRoot` checks (AKS phase) | Running as root (image default) |
| Exec-form `ENTRYPOINT` | Java is the container's main process (PID 1) and receives the platform's stop signal (SIGTERM) directly, which graceful shutdown needs | Shell form (`/bin/sh -c ...`), where the shell receives the signal instead |
| `JAVA_TOOL_OPTIONS` | `MaxRAMPercentage=75`: the heap follows the container's memory (1536 MB at 2 GiB). `ExitOnOutOfMemoryError`: a JVM out of memory exits and the platform restarts the container. `file.encoding=UTF-8`: independent of the base image's locale. Can be replaced at run time | Fixed `-Xmx`, which must be changed with every container size |
| No `HEALTHCHECK` instruction | Container Apps and Kubernetes use their own HTTP probes on `/actuator/health/liveness` and `/readiness`; compose defines its own health check | A Dockerfile `HEALTHCHECK`, which these platforms ignore |

**Monitoring agent (added in Phase 5).** The build stage also downloads the Azure Application Insights Java agent
3.7.10 through Maven (Maven Central checksums) and checks it against a pinned SHA-256; the runtime image contains it
as `/app/applicationinsights-agent.jar`, owned by root. It is **not** loaded by default: in Azure the app sets
`JDK_JAVA_OPTIONS=-javaagent:/app/applicationinsights-agent.jar` (read by the `java` launcher in addition to
`JAVA_TOOL_OPTIONS`) and the connection string, so local runs behave exactly as before. The agent adds about 4 s to
the startup and no critical or high findings to the scan. See [05-scaling-monitoring.md](05-scaling-monitoring.md).

Image layers as reported by `docker history`: dependencies 78.1 MB, Spring Boot loader 0.7 MB, snapshot
dependencies 4 kB (none today), application 2.1 MB.

## 4. Build and run

From the repository root (the commands are the same in bash and PowerShell):

```bash
docker build -t trebol-api:local trebol-backend-monolith
```

The first build downloads all Maven dependencies (a few minutes); later builds take about 1 to 2.5 minutes. On
networks where downloads from Maven Central stall or time out, add:

```bash
--build-arg MAVEN_EXTRA_ARGS="-U -Daether.connector.http.retryHandler.count=10 -Daether.dependencyCollector.bf.threads=1 -Daether.connector.basic.threads=1"
```

Run on the in-memory H2 database, with the CPU and memory of a development replica in Azure:

```bash
docker run --rm --name trebol-api -p 8080:8080 --cpus 1 --memory 2g trebol-api:local
bash test-endpoints.sh            # from the repository root, in a second terminal: 45 checks
docker stop -t 40 trebol-api      # graceful: requests in progress are completed first
```

To run the image against MySQL with profile `azure`, pass the environment variables listed in
[01-analysis.md, section 7](01-analysis.md#7-configuration); the compose stack below does this for you.

## 5. Local stack with docker-compose

```bash
cp .env.example .env              # then choose your own local values (PowerShell: Copy-Item .env.example .env)
docker compose up --build --wait  # builds the image, starts MySQL, then the API once MySQL is healthy
bash test-endpoints.sh            # 45 checks against http://localhost:8080
docker compose down               # keeps the database volume; add -v to delete it
```

| Design point | Reason |
|---|---|
| MySQL 8.4 with a health check on TCP `127.0.0.1` | The check only passes once the real server runs, not the temporary one MySQL uses during its first initialisation |
| API starts only when MySQL is healthy (`depends_on: condition: service_healthy`) | Avoids start-up failures and restarts while the database initialises |
| No published MySQL port | The database is reachable only from the API container, like the private database in Azure |
| Named volume `mysql-data` | Data survives `docker compose down` / `up`; Flyway then reports that no migration is necessary |
| Values from `.env` with `${VAR:?}` | No password in a committed file; compose refuses to start if a value is missing |
| API health check on `/actuator/health/readiness` | Same signal the platform uses |
| `stop_grace_period: 40s` | Longer than the application's 30 s graceful shutdown |

Verified: both services healthy in about 40 to 60 seconds, smoke test 45/45, MySQL port closed on the host, data
still present after `down` and `up`.

## 6. Verified runtime behaviour

| Check (laptop, Docker Desktop) | Result |
|---|---|
| Startup with 1 vCPU / 2 GiB (H2) | about 42 s with Spring Boot 3.5.16 (36 s with Spring Boot 3.2.9) |
| Maximum heap with 2 GiB | 1536 MB (75%) |
| User and file permissions | uid 10001; `/app` not writable |
| `docker stop` during a 20-second request | Spring logs "Commencing graceful shutdown", new requests are refused, the running request still receives its full response, then "Graceful shutdown complete"; exit code 143 (ended by SIGTERM, not killed) |
| Comparison with `server.shutdown=immediate` (the old default; tested outside Docker on 11 Nov) | The running request is cut off (empty reply) |
| Smoke test | 45/45 against the container (H2) and against the compose stack (MySQL) |

## 7. Vulnerability scan

Tool: **Trivy 0.76.2**, run as a container, so nothing needs installing. The gate used locally and planned for
the pipeline:

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy-cache:/root/.cache/ \
  -v "$PWD:/repo:ro" aquasec/trivy:0.76.2 image --scanners vuln --severity CRITICAL --exit-code 1 \
  --ignorefile /repo/.trivyignore.yaml trebol-api:local
```

(In Git Bash on Windows, prefix the command with `MSYS_NO_PATHCONV=1`; in PowerShell, write `"${PWD}:/repo:ro"`
and put the command on one line. Add `--show-suppressed` to list the accepted findings with their reasons.)

| Severity | Spring Boot 3.2.9 (first scan) | Spring Boot 3.5.16 + overrides |
|---|---|---|
| CRITICAL | 11 | 2 found, **0 after the documented exceptions** |
| HIGH | 34 | 2 |
| MEDIUM | 38 | 3 |
| LOW | 14 | 0 |

The first scan found almost everything in Java libraries (embedded Tomcat 10.1.28, Spring Security 6.2.6,
Spring Web MVC 6.1.12, Jackson 2.15.4), and only one finding in the Alpine OS packages. The fix was Spring Boot
3.2.9 → 3.5.16 (the last 3.x line), with two version overrides for fixes newer than that release:
Tomcat 10.1.61 and Jackson 2.21.8. springdoc moved to 2.8.17 for compatibility. The 372 tests and the smoke test
pass on the new versions.

**Accepted findings** (`.trivyignore.yaml`, each scoped to `spring-webmvc` 6.2.19 and expiring on 31 Jan 2027):

| CVE | Condition for exploitation | Why it does not apply here | Fix |
|---|---|---|---|
| CVE-2026-47884 | Views rendered with `XsltView` and a `/**` mapping that renders a view without an explicit name | The API only returns JSON from `@RestController` methods; there are no views | Spring Framework 7.0.9 only |
| CVE-2026-47890 | Server-Sent Events combined with view fragments | No SSE (`SseEmitter`, `text/event-stream`) and no views anywhere in the code | Spring Framework 7.0.9 only |

Neither has a public fix in Spring Framework 6.x, so both disappear with the planned move to Spring Boot 4. The
expiry date makes the scan report them again if that has not happened by then.

**Remaining non-critical findings:**

- HIGH, CVE-2024-49203 (QueryDSL 5.1.0, `orderBy` injection): disputed, no fixed version exists. Not reachable
  here: a requested sort field is only used as a key into a fixed map of predefined sort expressions, so request
  text never becomes part of a query.
- MEDIUM: `zlib` in Alpine (fixed in a newer Alpine package; picked up by rebuilding on a newer base image),
  `commons-lang3` 3.12.0 (pinned in the pom; fixed in 3.18.0) and `log4j-api` 2.24.3 (fixed in 2.25.5).
  Candidates for the next dependency update.

## 8. Limitations and next steps

- The two accepted findings remain until the application moves to Spring Boot 4 (Spring Framework 7).
- Startup takes about 42 s on 1 vCPU. Probes and minimum replicas must allow for it (Phase 5); Spring Boot's
  class data sharing (CDS) support is a candidate for reducing it.
- Base images must be rebuilt regularly to receive OS patches; the pipeline (Phase 4) will build and scan every
  change.
- In the pipeline the Maven cache mount starts empty unless it is cached between runs; GitHub's network makes the
  download acceptable.
