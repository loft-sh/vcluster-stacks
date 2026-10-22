# Build from this directory: docker build -t gpu-burn-in-recorder .
# The build stage runs on the builder's own platform and cross-compiles: Go needs no emulation,
# which keeps the arm64 image as fast to build as the amd64 one.
FROM --platform=$BUILDPLATFORM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /recorder .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /recorder /recorder
USER 65532:65532
ENTRYPOINT ["/recorder"]
