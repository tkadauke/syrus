# Docker Compose networking

The single-host Docker Compose distribution publishes the web container on
`127.0.0.1:3000` by default. `SYRUS_BIND` selects the host interface and
`SYRUS_PORT` selects the host port; both live in the install's `.env` file.

Keep `SYRUS_BIND=127.0.0.1` for a workstation install. This matters during
bootstrap because the first account created is the instance administrator.
Binding plain HTTP to every interface would let another host that can route to
the port reach that signup flow before the operator does.

Remote access is an explicit operator choice. Put an HTTPS reverse proxy in
front of Syrus, set the public `SYRUS_APP_HOST`, enable
`SYRUS_ASSUME_SSL=true`, and set `SYRUS_BIND=0.0.0.0` only if the proxy cannot
reach the loopback listener. Use firewall rules so clients cannot bypass the
proxy and connect to the plain-HTTP Compose port directly. Restart the stack
after changing `.env`.

## External plugin volume

Compose creates the optional `syrus-plugins` named volume and exposes it to
every Rails-booting service at `/home/rails/plugins-external` with
`SYRUS_PLUGIN_PATH` set to that directory. The setup, web, worker, and preview
services mount it read-only. An empty volume preserves the normal bundled-only
behavior.

The placeholder `plugin-installer` service is the sole service with a writable
mount. It exits without changing the volume; installation behavior belongs to
later installer work. Until that exists, operators may populate the volume
deliberately with a one-off container, then restart the Rails services so plugin
discovery runs again.
