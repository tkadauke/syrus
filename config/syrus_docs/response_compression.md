# Response compression

Syrus gzip-compresses dynamic JSON, JSONL, and HTML responses of at least 1 KiB.
The behavior is part of the Rails middleware stack, so it also applies when the
server is run without the Docker image's Thruster proxy. Action Cable, server-
sent events, already encoded responses, and smaller bodies are not compressed.

Check a running instance with a response expected to exceed 1 KiB:

```bash
curl -H 'Accept-Encoding: gzip' -I https://syrus.example/api/v1/app/jobs
```

Eligible responses include `Content-Encoding: gzip` and
`Vary: Accept-Encoding`.
