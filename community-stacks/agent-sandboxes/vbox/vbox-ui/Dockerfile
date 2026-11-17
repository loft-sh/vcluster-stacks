# syntax=docker/dockerfile:1

# Multi-stage build for the Next.js standalone output (next.config.ts sets
# output: "standalone"). The runtime image holds server.js, the traced
# node_modules it needs and the static assets, nothing else.
#
#   docker build -t vbox-ui:dev .
#   docker run --rm -p 3000:3000 vbox-ui:dev

ARG NODE_VERSION=24-alpine

FROM node:${NODE_VERSION} AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

FROM node:${NODE_VERSION} AS builder
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

FROM node:${NODE_VERSION} AS runner
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0 \
    VBOX_DATA_DIR=/data

# Numeric UID/GID so Kubernetes can verify runAsNonRoot without a user lookup.
RUN addgroup -S -g 10001 vbox && adduser -S -u 10001 -G vbox -h /app vbox \
    && mkdir -p /data && chown 10001:10001 /data

COPY --from=builder --chown=10001:10001 /app/.next/standalone ./
COPY --from=builder --chown=10001:10001 /app/.next/static ./.next/static

USER 10001:10001
EXPOSE 3000
# The audit trail and the sign-in settings and sessions (SQLite). Mount a
# PersistentVolumeClaim here, or both are lost with the pod.
VOLUME ["/data"]

# With readOnlyRootFilesystem, mount an emptyDir at /app/.next/cache: Next.js
# writes its fetch and image cache there at runtime.
CMD ["node", "server.js"]
