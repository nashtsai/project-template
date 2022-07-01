# Build the manager binary
FROM --platform=${BUILDPLATFORM} golang:1.17.6 as builder

## docker buildx buid injected build-args:
#BUILDPLATFORM — matches the current machine. (e.g. linux/amd64)
#BUILDOS — os component of BUILDPLATFORM, e.g. linux
#BUILDARCH — e.g. amd64, arm64, riscv64
#BUILDVARIANT — used to set ARM variant, e.g. v7
#TARGETPLATFORM — The value set with --platform flag on build
#TARGETOS - OS component from --platform, e.g. linux
#TARGETARCH - Architecture from --platform, e.g. arm64
#TARGETVARIANT

#ARG BUILDPLATFORM
ARG TARGETPLATFORM
ARG TARGETOS
ARG TARGETARCH

ARG ldflags="-s -w"
ARG goproxy="https://goproxy.cn,direct"
ARG gonoproxy=
ARG gonosumdb=
ARG goprivate=

ENV GOPROXY=${goproxy}
ENV GONOPROXY=${gonoproxy}
ENV GONOSUMDB=${gonosumdb}
ENV GOPRIVATE=${goprivate}

WORKDIR /workspace
# Copy the Go Modules manifests
COPY go.mod go.mod
COPY go.sum go.sum

# TMP hack on copy vendor/ as modernc.org/cc@v1.0.0 cannot be found
# COPY vendor/ vendor/

# cache deps before building and copying source so that we don't need to re-download as much
# and so that source changes don't invalidate our downloaded layer
# RUN go mod download

# Copy the go source
COPY api/ api/
COPY cmd/ cmd/
COPY gen/ gen/
COPY pkg/ pkg/
COPY internal/ internal/
COPY third_party/ third_party/
COPY tools/ main.go .
# COPY pkg/ pkg/
# COPY main.go api/ controllers/ pkg/ .

# Build
#RUN --mount=target=. \
#    --mount=type=cache,target=/root/.cache/go-build \
#    --mount=type=cache,target=/go/pkg \
RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} CGO_ENABLED=0 go build -ldflags="${ldflags}" -o app main.go


# Use distroless as minimal base image to package the manager binary
# Refer to https://github.com/GoogleContainerTools/distroless for more details
FROM gcr.io/distroless/static:nonroot

WORKDIR /
COPY --from=builder /workspace/app .
USER nonroot:nonroott

ENTRYPOINT ["/app"]
