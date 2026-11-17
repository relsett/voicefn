# VoiceFn website

The pages the App Store links to: home (`/`), privacy policy (`/privacy`) and support (`/support`),
in English and Russian, plus `/healthz`. `SUPPORT_EMAIL` (optional) is shown on privacy and support;
`LISTEN` defaults to `:8080`.

```sh
go test ./...
deploy/deploy   # build and restart on the host behind Caddy (voicefn.driftstatic.com)
```
