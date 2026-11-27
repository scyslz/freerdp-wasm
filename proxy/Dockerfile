# wsproxy - single-file WS/TCP proxy with the WASM client embedded.

FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
COPY site/ ./site/
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/wsproxy .

FROM scratch
COPY --from=build /out/wsproxy /wsproxy
# Pass -target at runtime, e.g.
#   docker run --rm -p 8180:8180 wasm-poc-wsproxy -target 192.168.1.10:3389
EXPOSE 8180
ENTRYPOINT ["/wsproxy"]
CMD ["-listen", "0.0.0.0:8180"]
