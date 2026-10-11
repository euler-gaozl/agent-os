FROM node:24-alpine AS web
WORKDIR /src/web
COPY web/package.json web/pnpm-lock.yaml ./
RUN corepack enable && corepack prepare pnpm@11.25.0 --activate && pnpm install --frozen-lockfile
COPY web/ ./
RUN pnpm run build

FROM golang:1.27.2-alpine AS backend
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/ cmd/
COPY internal/ internal/
RUN CGO_ENABLED=0 go build -trimpath -o /agentos ./cmd/agentos

FROM alpine:3.22
RUN apk add --no-cache ca-certificates docker-cli && adduser -D -u 10001 agentos
WORKDIR /app
COPY --from=backend /agentos /usr/local/bin/agentos
COPY --from=web /src/web/dist /app/web/dist
COPY --from=web /src/web/dist-futures /app/web/dist-futures
COPY packs/ /app/packs/
USER 10001
ENTRYPOINT ["agentos"]
