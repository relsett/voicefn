FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
COPY site ./site
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /voicefn-site .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /voicefn-site /voicefn-site
ENV LISTEN=:8080
EXPOSE 8080
ENTRYPOINT ["/voicefn-site"]
