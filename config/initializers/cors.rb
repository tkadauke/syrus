# Explicit, deny-by-default CORS policy.
#
# The React SPA, admin API, and app API are all served same-origin by the
# Syrus web pod, so no browser origin needs cross-origin access by default.
# Leaving CORS entirely unconfigured relies on every browser correctly
# refusing to expose the response to cross-origin JS; this makes the "no
# origins allowed" posture an explicit, auditable policy instead of an
# accident of omission.
#
# Self-hosters who need cross-origin browser access to the API (e.g. a
# separate first-party dashboard domain) should list specific trusted
# origins below — never "*" for an API that accepts bearer tokens.
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins [] # no origins allowed by default

    resource "/api/*",
      headers: :any,
      methods: %i[get post put patch delete options head],
      credentials: false
  end
end
