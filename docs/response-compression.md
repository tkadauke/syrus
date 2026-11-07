# Response compression

Syrus compresses dynamic `application/json`, `application/jsonl`, and
`text/html` responses with gzip when the client advertises support. Responses
smaller than 1 KiB, Action Cable traffic, server-sent events, and responses
that already have a `Content-Encoding` are left unchanged. The last rule means
the application does not double-compress responses when it runs behind
Thruster or another compression proxy.

The Docker image starts Rails through Thruster. The bundled Thruster 0.1.27
documentation says response gzip compression is enabled by default through
`GZIP_COMPRESSION_ENABLED`; this applies to the JSON, JSONL, and HTML content
types above. Rack compression remains enabled so direct Puma and other
non-Thruster deployments have the same behavior. Static assets are handled
separately by `Syrus::PrecompressedAssetServer`, which prefers build-time
Brotli or gzip variants.

Check a deployed response by sending an explicit encoding preference:

```sh
curl -H 'Accept-Encoding: gzip' -I https://syrus.example/api/v1/app/jobs
curl -H 'Accept-Encoding: gzip' -I https://syrus.example/app
```

For a response larger than the threshold, expect `Content-Encoding: gzip` and
`Vary: Accept-Encoding`. Authentication and authorization still apply to the
chosen URL, so include the same cookie or authorization header used by the
client when checking a protected endpoint.
