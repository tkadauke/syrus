# Response compression

Syrus compresses dynamic `application/json`, `application/jsonl`, and
`text/html` responses of at least 1 KiB with `Rack::Deflater`. This applies to
Docker and non-Docker launches. Responses that are already encoded are left
alone, so an upstream or downstream proxy does not cause double compression.
Action Cable (`/cable`) and `text/event-stream` responses are excluded to keep
streaming unbuffered.

The Docker image starts Rails through Thruster (`Dockerfile` and `bin/thrust`).
The locked Thruster 0.1.27 implementation enables gzip by default, uses a 1 KiB
minimum, and accepts JSON, JSONL, and HTML through its default content-type
filter. Rack therefore provides the same coverage when Rails is run without
Thruster; when Thruster is present it sees Rack's `Content-Encoding` and must
not encode the response a second time. Static fingerprinted assets continue to
use their precompressed Brotli or gzip variants.

This is a static configuration audit, not a production measurement. To verify
a running installation, choose a response larger than 1 KiB and inspect its
headers:

```bash
curl -H 'Accept-Encoding: gzip' -I https://syrus.example/api/v1/app/jobs
curl -H 'Accept-Encoding: gzip' -I https://syrus.example/
```

An eligible response should include `Content-Encoding: gzip` and
`Vary: Accept-Encoding`. A small response, an SSE endpoint, or `/cable` should
not include gzip encoding.
