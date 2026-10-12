FROM node:24-alpine AS web
WORKDIR /src/web
COPY web/package.json web/pnpm-lock.yaml web/pnpm-workspace.yaml ./
RUN corepack enable && corepack prepare pnpm@11.25.0 --activate && pnpm install --frozen-lockfile
COPY web/ ./
RUN pnpm run build

FROM node:24-alpine AS harness
WORKDIR /app/harness
COPY harness/package.json harness/pnpm-lock.yaml ./
RUN corepack enable && corepack prepare pnpm@11.25.0 --activate && pnpm install --frozen-lockfile --prod
COPY harness/runner.mjs ./

FROM golang:1.27.2-alpine AS backend
ARG SERVICE
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/ cmd/
COPY internal/ internal/
COPY services/ services/
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /service ./cmd/${SERVICE} && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /healthcheck ./cmd/healthcheck

FROM alpine:3.23 AS service
LABEL org.agentos.builtin-tools='["knowledge_search","note_save","artifact_read","spawn_agent","sandbox_exec","document_read","run_recall"]'
RUN apk add --no-cache ca-certificates && adduser -D -u 10001 agentos
WORKDIR /app
COPY --from=backend /service /app/service
COPY --from=backend /healthcheck /app/healthcheck
USER 10001
ENTRYPOINT ["/app/service", "--config", "/run/service.json"]

FROM service AS control
COPY --from=web /src/web/dist /app/web/dist
FROM service AS futures
COPY --from=web /src/web/dist-futures /app/web/dist-futures

FROM node:24-alpine AS worker
LABEL org.agentos.worker-engines='["legacy-go","dsh-0.2.0-rc.2","dsh-0.2.0-rc.2-evidence-v1"]'
LABEL org.agentos.builtin-tools='["knowledge_search","note_save","artifact_read","spawn_agent","sandbox_exec","document_read","run_recall"]'
RUN apk add --no-cache ca-certificates && adduser -D -u 10001 agentos
WORKDIR /app
COPY --from=backend /service /app/service
COPY --from=backend /healthcheck /app/healthcheck
COPY --from=harness /app/harness /app/harness
ENV NODE_OPTIONS=--max-old-space-size=192
USER 10001
ENTRYPOINT ["/app/service", "--config", "/run/service.json"]

FROM service AS sandbox
USER root
RUN apk add --no-cache docker-cli
USER 10001

FROM service AS migration
USER root
ENTRYPOINT ["sh", "-c", "/app/service --output /config && chown 10001:10001 /config/*.json"]
