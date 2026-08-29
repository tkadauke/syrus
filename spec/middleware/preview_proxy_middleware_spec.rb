require "rails_helper"

RSpec.describe PreviewProxyMiddleware do
  let(:inner_app) { ->(_env) { [200, { "Content-Type" => "text/plain" }, ["upstream"]] } }
  let(:middleware) { described_class.new(inner_app) }
  let(:job) { Factories.job }

  def env_for(host:, path: "/", method: "GET", body: nil, query: nil, cookie: nil)
    url = "http://#{host}#{path}"
    url += "?#{query}" if query
    opts = { method: method }
    opts["CONTENT_TYPE"] = "application/x-www-form-urlencoded" if body
    opts[:input] = body if body
    rack_env = Rack::MockRequest.env_for(url, opts)
    rack_env["HTTP_HOST"] = host
    rack_env["HTTP_COOKIE"] = cookie if cookie
    rack_env
  end

  def create_running_env(job:, port: 25000, internal_host: "127.0.0.1")
    PreviewEnvironment.create!(
      job: job,
      workspace_path: "/tmp/workspace",
      state: "running",
      internal_host: internal_host,
      port: port,
      expires_at: 10.minutes.from_now,
      last_activity_at: 1.minute.ago
    )
  end

  describe "passthrough for non-preview hosts" do
    it "passes through requests for the main app domain" do
      status, _, body = middleware.call(env_for(host: "syrus.example.com"))
      expect(status).to eq(200)
      expect(body).to eq(["upstream"])
    end

    it "passes through requests for subdomains that don't match the pattern" do
      status, _, body = middleware.call(env_for(host: "other.lvh.me"))
      expect(status).to eq(200)
      expect(body).to eq(["upstream"])
    end

    it "passes through requests with no host header" do
      env = env_for(host: "syrus.example.com")
      env.delete("HTTP_HOST")
      status, _, body = middleware.call(env)
      expect(status).to eq(200)
      expect(body).to eq(["upstream"])
    end

    it "ignores hosts that have the wrong numeric suffix format" do
      status, _, _ = middleware.call(env_for(host: "preview-abc.lvh.me"))
      # abc doesn't parse to a matching job, so passthrough
      # (the regex requires \d+, so this won't match)
      expect(status).to eq(200)
    end
  end

  describe "preview host with a running environment" do
    let!(:preview_env) { create_running_env(job: job) }

    before do
      stub_request(:get, "http://127.0.0.1:25000/")
        .to_return(status: 200, body: "hello from preview", headers: { "content-type" => "text/html" })
    end

    it "proxies the request to the internal host and port" do
      status, headers, body = middleware.call(env_for(host: "preview-#{preview_env.id}.lvh.me"))
      expect(status).to eq(200)
      expect(body).to eq(["hello from preview"])
      expect(headers["content-type"]).to eq("text/html")
    end

    it "uses localhost authority headers for the preview app while preserving the public host separately" do
      stub_request(:get, "http://127.0.0.1:25000/")
        .with(headers: {
          "Host" => "localhost:25000",
          "X-Forwarded-Host" => "localhost:25000",
          "X-Forwarded-Proto" => "http",
          "X-Syrus-Preview-Host" => "preview-#{preview_env.id}.lvh.me",
          "X-Syrus-Preview-Proto" => "http"
        })
        .to_return(status: 200, body: "host ok", headers: {})

      status, _, body = middleware.call(env_for(host: "preview-#{preview_env.id}.lvh.me"))
      expect(status).to eq(200)
      expect(body).to eq(["host ok"])
    end

    it "normalizes same-origin browser Origin and Referer headers for the proxied app" do
      stub_request(:post, "http://127.0.0.1:25000/api/signup")
        .with(headers: {
          "Origin" => "http://localhost:25000",
          "Referer" => "http://localhost:25000/signup"
        })
        .to_return(status: 201, body: "created", headers: {})

      env = env_for(host: "preview-#{preview_env.id}.lvh.me", path: "/api/signup", method: "POST")
      env["HTTP_ORIGIN"] = "http://preview-#{preview_env.id}.lvh.me"
      env["HTTP_REFERER"] = "http://preview-#{preview_env.id}.lvh.me/signup"

      status, _, body = middleware.call(env)

      expect(status).to eq(201)
      expect(body).to eq(["created"])
    end

    it "proxies with path and query string" do
      stub_request(:get, "http://127.0.0.1:25000/dashboard?tab=logs")
        .to_return(status: 200, body: "dashboard", headers: {})
      status, _, body = middleware.call(env_for(host: "preview-#{preview_env.id}.lvh.me", path: "/dashboard", query: "tab=logs"))
      expect(status).to eq(200)
      expect(body).to eq(["dashboard"])
    end

    it "preserves non-200 status codes from the upstream" do
      stub_request(:get, "http://127.0.0.1:25000/missing")
        .to_return(status: 404, body: "not found", headers: {})
      status, _, _ = middleware.call(env_for(host: "preview-#{preview_env.id}.lvh.me", path: "/missing"))
      expect(status).to eq(404)
    end

    it "strips hop-by-hop headers from the upstream response" do
      stub_request(:get, "http://127.0.0.1:25000/")
        .to_return(status: 200, body: "", headers: {
          "connection" => "keep-alive",
          "transfer-encoding" => "chunked",
          "content-type" => "text/html"
        })
      _, headers, _ = middleware.call(env_for(host: "preview-#{preview_env.id}.lvh.me"))
      expect(headers.keys).not_to include("connection", "transfer-encoding")
      expect(headers["content-type"]).to eq("text/html")
    end

    it "uses preview-safe browser policy headers instead of restrictive upstream headers" do
      stub_request(:get, "http://127.0.0.1:25000/")
        .to_return(status: 200, body: "preview", headers: {
          "content-security-policy" => "default-src 'self'; script-src 'self'; style-src 'self'",
          "content-security-policy-report-only" => "default-src 'none'",
          "x-frame-options" => "DENY",
          "permissions-policy" => "fullscreen=()"
        })

      _, headers, _ = middleware.call(env_for(host: "preview-#{preview_env.id}.lvh.me"))

      expect(headers).not_to have_key("content-security-policy")
      expect(headers).not_to have_key("content-security-policy-report-only")
      expect(headers).not_to have_key("x-frame-options")
      expect(headers).not_to have_key("permissions-policy")
      expect(headers["Content-Security-Policy"]).to include("script-src 'self' 'unsafe-inline' 'unsafe-eval' http: https: data: blob:")
      expect(headers["Content-Security-Policy"]).to include("style-src 'self' 'unsafe-inline'")
      expect(headers["Content-Security-Policy"]).to include("connect-src 'self' http: https: data: blob: ws: wss:")
      expect(headers["Content-Security-Policy"]).to include("frame-src 'self' http: https: data: blob:")
      expect(headers["Content-Security-Policy"]).to include("child-src 'self' http: https: data: blob:")
    end

    it "rewrites browser-facing localhost asset origins in HTML responses" do
      stub_request(:get, "http://127.0.0.1:25000/")
        .to_return(
          status: 200,
          body: '<script type="module" src="http://localhost:3036/builds/main.tsx"></script>',
          headers: {
            "content-type" => "text/html; charset=utf-8",
            "content-length" => "72",
            "etag" => 'W/"abc"'
          }
        )

      status, headers, body = middleware.call(env_for(host: "preview-#{preview_env.id}.lvh.me"))

      expect(status).to eq(200)
      expect(body.join).to include('src="/builds/main.tsx"')
      expect(body.join).not_to include("localhost:3036")
      expect(headers.keys.map(&:downcase)).not_to include("content-length", "etag")
    end

    it "leaves non-HTML localhost text responses alone" do
      stub_request(:get, "http://127.0.0.1:25000/api")
        .to_return(
          status: 200,
          body: '{"url":"http://localhost:3036/builds/main.tsx"}',
          headers: { "content-type" => "application/json" }
        )

      _, _, body = middleware.call(env_for(host: "preview-#{preview_env.id}.lvh.me", path: "/api"))

      expect(body.join).to include("http://localhost:3036")
    end

    it "resets last_activity_at on each proxied request" do
      freeze_time do
        middleware.call(env_for(host: "preview-#{preview_env.id}.lvh.me"))
        preview_env.reload
        expect(preview_env.last_activity_at).to be_within(1.second).of(Time.current)
      end
    end

    it "extends expires_at on each proxied request" do
      freeze_time do
        middleware.call(env_for(host: "preview-#{preview_env.id}.lvh.me"))
        preview_env.reload
        expect(preview_env.expires_at).to be_within(1.second).of(
          PreviewEnvironment::DEFAULT_TTL_MINUTES.minutes.from_now
        )
      end
    end

    it "respects a custom base domain configured via SYRUS_PREVIEW_BASE_DOMAIN" do
      stub_const("ENV", ENV.to_h.merge("SYRUS_PREVIEW_BASE_DOMAIN" => "preview.example.com"))
      custom_middleware = described_class.new(inner_app)

      other_preview = PreviewEnvironment.create!(
        job: Factories.job,
        workspace_path: "/tmp/workspace",
        state: "running",
        internal_host: "127.0.0.1",
        port: 25001,
        expires_at: 10.minutes.from_now
      )
      stub_request(:get, "http://127.0.0.1:25001/")
        .to_return(status: 200, body: "custom domain preview", headers: {})

      status, _, body = custom_middleware.call(env_for(host: "preview-#{other_preview.id}.preview.example.com"))
      expect(status).to eq(200)
      expect(body).to eq(["custom domain preview"])
    end
  end

  describe "preview host for a repository-scoped environment (no job)" do
    it "proxies the request the same way as a job-scoped environment" do
      repo_preview = PreviewEnvironment.create!(
        repository: job.repository,
        workspace_path: "/tmp/workspace",
        state: "running",
        internal_host: "127.0.0.1",
        port: 25002,
        expires_at: 10.minutes.from_now,
        last_activity_at: 1.minute.ago
      )
      stub_request(:get, "http://127.0.0.1:25002/")
        .to_return(status: 200, body: "main branch preview", headers: { "content-type" => "text/html" })

      status, _, body = middleware.call(env_for(host: "preview-#{repo_preview.id}.lvh.me"))

      expect(status).to eq(200)
      expect(body).to eq(["main branch preview"])
    end
  end

  describe "preview host with no running environment" do
    it "returns 503 when no preview environment exists for that id" do
      status, headers, body = middleware.call(env_for(host: "preview-999999.lvh.me"))
      expect(status).to eq(503)
      expect(headers["Content-Type"]).to include("text/html")
      expect(body.join).to include("Preview not available")
    end

    it "includes a message directing the user to the Syrus UI" do
      _, _, body = middleware.call(env_for(host: "preview-999999.lvh.me"))
      expect(body.join).to include("Syrus UI")
    end
  end

  describe "preview host with a non-running environment" do
    PreviewEnvironment::ACTIVE_STATES.reject { |s| s == "running" }.each do |state|
      it "returns 503 when environment is in '#{state}' state" do
        env = PreviewEnvironment.create!(job: job, workspace_path: "/tmp", state: state)
        status, _, _ = middleware.call(env_for(host: "preview-#{env.id}.lvh.me"))
        expect(status).to eq(503)
      end
    end

    it "returns 503 when environment is stopped" do
      env = PreviewEnvironment.create!(job: job, workspace_path: "/tmp", state: "stopped")
      status, _, _ = middleware.call(env_for(host: "preview-#{env.id}.lvh.me"))
      expect(status).to eq(503)
    end
  end

  describe "proxy error handling" do
    let!(:preview_env) { create_running_env(job: job) }

    it "returns 502 when the upstream connection fails" do
      stub_request(:get, "http://127.0.0.1:25000/").to_raise(Errno::ECONNREFUSED)
      status, _, body = middleware.call(env_for(host: "preview-#{preview_env.id}.lvh.me"))
      expect(status).to eq(502)
      expect(body.join).to include("Proxy error")
    end
  end

  describe "POST request proxying" do
    let!(:preview_env) { create_running_env(job: job) }

    it "proxies POST requests with body" do
      stub_request(:post, "http://127.0.0.1:25000/submit")
        .with(body: "field=value")
        .to_return(status: 201, body: "created", headers: {})

      env = env_for(host: "preview-#{preview_env.id}.lvh.me", path: "/submit", method: "POST", body: "field=value")
      status, _, body = middleware.call(env)
      expect(status).to eq(201)
      expect(body).to eq(["created"])
    end
  end

  describe "host with port number" do
    let!(:preview_env) { create_running_env(job: job) }

    it "matches hosts with an explicit port" do
      stub_request(:get, "http://127.0.0.1:25000/")
        .to_return(status: 200, body: "ok", headers: {})
      status, _, _ = middleware.call(env_for(host: "preview-#{preview_env.id}.lvh.me:3000"))
      expect(status).to eq(200)
    end
  end

  describe "preview panel hosts" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }
    let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

    # Generic streaming/versioning/CSP behavior below isn't exercising the
    # access-control gate, so default these panels to public rather than
    # threading a valid token through every one of them. Access control
    # itself is covered by the dedicated "panel access control" group.
    def create_panel(**attrs)
      PreviewPanel.create!({ chat_session: chat_session, title: "Widget preview", visibility: "public" }.merge(attrs))
    end

    it "streams the index.html attachment for the panel root path" do
      panel = create_panel
      panel.create_version!("index.html" => "<h1>hello</h1>")

      status, headers, body = middleware.call(env_for(host: "preview-panel-#{panel.id}.lvh.me"))

      expect(status).to eq(200)
      expect(headers["Content-Type"]).to eq("text/html")
      expect(body.join).to eq("<h1>hello</h1>")
    end

    it "streams the stored entry attachment for the panel root path" do
      panel = create_panel
      panel.create_version!({ "notes.md" => "# Notes", "index.html" => "<h1>fallback</h1>" }, entry_file: "notes.md")

      status, headers, body = middleware.call(env_for(host: "preview-panel-#{panel.id}.lvh.me"))

      expect(status).to eq(200)
      expect(headers["Content-Type"]).to eq("text/markdown")
      expect(body.join).to eq("# Notes")
    end

    it "resolves the selected entry per requested version" do
      panel = create_panel
      first_version = panel.create_version!({ "notes.md" => "# V1" }, entry_file: "notes.md")
      panel.create_version!({ "report.pdf" => "%PDF-1.4" }, entry_file: "report.pdf")

      status, headers, body = middleware.call(env_for(host: "preview-panel-#{panel.id}.lvh.me", query: "v=#{first_version.id}"))

      expect(status).to eq(200)
      expect(headers["Content-Type"]).to eq("text/markdown")
      expect(body.join).to eq("# V1")
    end

    it "defaults to the panel's current (latest) version when no v param is given" do
      panel = create_panel
      panel.create_version!("index.html" => "<h1>v1</h1>")
      panel.create_version!("index.html" => "<h1>v2</h1>")

      status, _, body = middleware.call(env_for(host: "preview-panel-#{panel.id}.lvh.me"))

      expect(status).to eq(200)
      expect(body.join).to eq("<h1>v2</h1>")
    end

    it "serves a specific older version via the v query param" do
      panel = create_panel
      first_version = panel.create_version!("index.html" => "<h1>v1</h1>")
      panel.create_version!("index.html" => "<h1>v2</h1>")

      status, _, body = middleware.call(env_for(host: "preview-panel-#{panel.id}.lvh.me", query: "v=#{first_version.id}"))

      expect(status).to eq(200)
      expect(body.join).to eq("<h1>v1</h1>")
    end

    it "returns 404 for an unknown version id" do
      panel = create_panel
      panel.create_version!("index.html" => "<h1>v1</h1>")

      status, _, _ = middleware.call(env_for(host: "preview-panel-#{panel.id}.lvh.me", query: "v=999999"))

      expect(status).to eq(404)
    end

    it "returns 404 for a panel with no versions yet" do
      panel = create_panel

      status, _, _ = middleware.call(env_for(host: "preview-panel-#{panel.id}.lvh.me"))

      expect(status).to eq(404)
    end

    it "streams a nested file by its relative path" do
      panel = create_panel
      panel.create_version!("index.html" => "<h1>hi</h1>", "css/app.css" => "body { color: red; }")

      status, headers, body = middleware.call(env_for(host: "preview-panel-#{panel.id}.lvh.me", path: "/css/app.css"))

      expect(status).to eq(200)
      expect(headers["Content-Type"]).to eq("text/css")
      expect(body.join).to eq("body { color: red; }")
    end

    it "infers the content type from the file extension" do
      panel = create_panel
      panel.create_version!("app.js" => "console.log('hi')")

      _, headers, _ = middleware.call(env_for(host: "preview-panel-#{panel.id}.lvh.me", path: "/app.js"))

      expect(headers["Content-Type"]).to eq("text/javascript")
    end

    it "applies the shared preview CSP" do
      panel = create_panel
      panel.create_version!("index.html" => "<h1>hi</h1>")

      _, headers, _ = middleware.call(env_for(host: "preview-panel-#{panel.id}.lvh.me"))

      expect(headers["Content-Security-Policy"]).to eq(described_class::PREVIEW_CSP)
    end

    it "returns 404 for an unknown panel id" do
      status, _, body = middleware.call(env_for(host: "preview-panel-999999.lvh.me"))

      expect(status).to eq(404)
      expect(body.join).to include("not found")
    end

    it "returns 404 for a closed panel" do
      panel = create_panel(state: "closed")
      panel.create_version!("index.html" => "<h1>hi</h1>")

      status, _, _ = middleware.call(env_for(host: "preview-panel-#{panel.id}.lvh.me"))

      expect(status).to eq(404)
    end

    it "returns 404 for a path with no matching attachment" do
      panel = create_panel
      panel.create_version!("index.html" => "<h1>hi</h1>")

      status, _, _ = middleware.call(env_for(host: "preview-panel-#{panel.id}.lvh.me", path: "/missing.js"))

      expect(status).to eq(404)
    end

    it "does not collide with the job preview host pattern" do
      status, _, body = middleware.call(env_for(host: "preview-panel-abc.lvh.me"))

      expect(status).to eq(200)
      expect(body).to eq(["upstream"])
    end

    it "respects a custom base domain configured via SYRUS_PREVIEW_BASE_DOMAIN" do
      stub_const("ENV", ENV.to_h.merge("SYRUS_PREVIEW_BASE_DOMAIN" => "preview.example.com"))
      custom_middleware = described_class.new(inner_app)
      panel = create_panel
      panel.create_version!("index.html" => "<h1>custom domain</h1>")

      status, _, body = custom_middleware.call(env_for(host: "preview-panel-#{panel.id}.preview.example.com"))

      expect(status).to eq(200)
      expect(body.join).to eq("<h1>custom domain</h1>")
    end
  end

  describe "panel access control" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }
    let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

    def create_panel(**attrs)
      panel = PreviewPanel.create!({ chat_session: chat_session, title: "Widget preview" }.merge(attrs))
      panel.create_version!("index.html" => "<h1>hi</h1>")
      panel
    end

    it "serves a public panel with no token at all" do
      panel = create_panel(visibility: "public")

      status, _, body = middleware.call(env_for(host: "preview-panel-#{panel.id}.lvh.me"))

      expect(status).to eq(200)
      expect(body.join).to eq("<h1>hi</h1>")
    end

    it "rejects a private panel with no token" do
      panel = create_panel(visibility: "private")

      status, _, body = middleware.call(env_for(host: "preview-panel-#{panel.id}.lvh.me"))

      expect(status).to eq(401)
      expect(body.join).to include("private")
    end

    it "rejects a private panel with a garbage token" do
      panel = create_panel(visibility: "private")

      status, _, _ = middleware.call(env_for(host: "preview-panel-#{panel.id}.lvh.me", query: "token=garbage"))

      expect(status).to eq(401)
    end

    it "rejects a token issued for a different panel" do
      panel = create_panel(visibility: "private")
      other_panel = create_panel(visibility: "private")
      token = PreviewPanel::AccessToken.issue(other_panel)

      status, _, _ = middleware.call(env_for(host: "preview-panel-#{panel.id}.lvh.me", query: "token=#{token}"))

      expect(status).to eq(401)
    end

    it "rejects an expired token" do
      panel = create_panel(visibility: "private")
      token = nil
      freeze_time { token = PreviewPanel::AccessToken.issue(panel) }

      status, _, _ = travel(PreviewPanel::AccessToken::TTL + 1.minute) do
        middleware.call(env_for(host: "preview-panel-#{panel.id}.lvh.me", query: "token=#{token}"))
      end

      expect(status).to eq(401)
    end

    it "serves a private panel with a valid query token and sets a follow-up access cookie" do
      panel = create_panel(visibility: "private")
      token = PreviewPanel::AccessToken.issue(panel)

      status, headers, body = middleware.call(env_for(host: "preview-panel-#{panel.id}.lvh.me", query: "token=#{token}"))

      expect(status).to eq(200)
      expect(body.join).to eq("<h1>hi</h1>")
      set_cookie = Array(headers["set-cookie"] || headers["Set-Cookie"]).join("; ")
      expect(set_cookie).to include("_syrus_preview_panel_access=#{token}")
      expect(set_cookie).to include("httponly")
      expect(set_cookie).to include("samesite=none")
    end

    it "serves a private panel using only the access cookie, without a query token" do
      panel = create_panel(visibility: "private")
      token = PreviewPanel::AccessToken.issue(panel)

      status, _, body = middleware.call(env_for(
        host: "preview-panel-#{panel.id}.lvh.me",
        cookie: "_syrus_preview_panel_access=#{token}"
      ))

      expect(status).to eq(200)
      expect(body.join).to eq("<h1>hi</h1>")
    end

    it "marks the access cookie secure when the request is https" do
      panel = create_panel(visibility: "private")
      token = PreviewPanel::AccessToken.issue(panel)

      env = env_for(host: "preview-panel-#{panel.id}.lvh.me", query: "token=#{token}")
      env["HTTPS"] = "on"
      _, headers, _ = middleware.call(env)

      set_cookie = Array(headers["set-cookie"] || headers["Set-Cookie"]).join("; ")
      expect(set_cookie).to include("secure")
    end
  end
end
