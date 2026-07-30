require "rails_helper"

RSpec.describe PreviewProxyMiddleware do
  let(:inner_app) { ->(_env) { [200, { "Content-Type" => "text/plain" }, ["upstream"]] } }
  let(:middleware) { described_class.new(inner_app) }
  let(:job) { Factories.job }

  def env_for(host:, path: "/", method: "GET", body: nil, query: nil)
    url = "http://#{host}#{path}"
    url += "?#{query}" if query
    opts = { method: method }
    opts["CONTENT_TYPE"] = "application/x-www-form-urlencoded" if body
    opts[:input] = body if body
    rack_env = Rack::MockRequest.env_for(url, opts)
    rack_env["HTTP_HOST"] = host
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
      status, headers, body = middleware.call(env_for(host: "preview-#{job.id}.lvh.me"))
      expect(status).to eq(200)
      expect(body).to eq(["hello from preview"])
      expect(headers["content-type"]).to eq("text/html")
    end

    it "proxies with path and query string" do
      stub_request(:get, "http://127.0.0.1:25000/dashboard?tab=logs")
        .to_return(status: 200, body: "dashboard", headers: {})
      status, _, body = middleware.call(env_for(host: "preview-#{job.id}.lvh.me", path: "/dashboard", query: "tab=logs"))
      expect(status).to eq(200)
      expect(body).to eq(["dashboard"])
    end

    it "preserves non-200 status codes from the upstream" do
      stub_request(:get, "http://127.0.0.1:25000/missing")
        .to_return(status: 404, body: "not found", headers: {})
      status, _, _ = middleware.call(env_for(host: "preview-#{job.id}.lvh.me", path: "/missing"))
      expect(status).to eq(404)
    end

    it "strips hop-by-hop headers from the upstream response" do
      stub_request(:get, "http://127.0.0.1:25000/")
        .to_return(status: 200, body: "", headers: {
          "connection" => "keep-alive",
          "transfer-encoding" => "chunked",
          "content-type" => "text/html"
        })
      _, headers, _ = middleware.call(env_for(host: "preview-#{job.id}.lvh.me"))
      expect(headers.keys).not_to include("connection", "transfer-encoding")
      expect(headers["content-type"]).to eq("text/html")
    end

    it "resets last_activity_at on each proxied request" do
      freeze_time do
        middleware.call(env_for(host: "preview-#{job.id}.lvh.me"))
        preview_env.reload
        expect(preview_env.last_activity_at).to be_within(1.second).of(Time.current)
      end
    end

    it "extends expires_at on each proxied request" do
      freeze_time do
        middleware.call(env_for(host: "preview-#{job.id}.lvh.me"))
        preview_env.reload
        expect(preview_env.expires_at).to be_within(1.second).of(
          PreviewEnvironment::DEFAULT_TTL_MINUTES.minutes.from_now
        )
      end
    end

    it "respects a custom base domain configured via SYRUS_PREVIEW_BASE_DOMAIN" do
      custom_middleware = described_class.new(inner_app)
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

      status, _, body = custom_middleware.call(env_for(host: "preview-#{other_preview.job_id}.preview.example.com"))
      expect(status).to eq(200)
      expect(body).to eq(["custom domain preview"])
    end
  end

  describe "preview host with no running environment" do
    it "returns 503 when no preview environment exists for the job" do
      status, headers, body = middleware.call(env_for(host: "preview-#{job.id}.lvh.me"))
      expect(status).to eq(503)
      expect(headers["Content-Type"]).to include("text/html")
      expect(body.join).to include("Preview not available")
    end

    it "includes a message directing the user to the Syrus UI" do
      _, _, body = middleware.call(env_for(host: "preview-#{job.id}.lvh.me"))
      expect(body.join).to include("Syrus UI")
    end
  end

  describe "preview host with a non-running environment" do
    PreviewEnvironment::ACTIVE_STATES.reject { |s| s == "running" }.each do |state|
      it "returns 503 when environment is in '#{state}' state" do
        PreviewEnvironment.create!(job: job, workspace_path: "/tmp", state: state)
        status, _, _ = middleware.call(env_for(host: "preview-#{job.id}.lvh.me"))
        expect(status).to eq(503)
      end
    end

    it "returns 503 when environment is stopped" do
      PreviewEnvironment.create!(job: job, workspace_path: "/tmp", state: "stopped")
      status, _, _ = middleware.call(env_for(host: "preview-#{job.id}.lvh.me"))
      expect(status).to eq(503)
    end
  end

  describe "proxy error handling" do
    let!(:preview_env) { create_running_env(job: job) }

    it "returns 502 when the upstream connection fails" do
      stub_request(:get, "http://127.0.0.1:25000/").to_raise(Errno::ECONNREFUSED)
      status, _, body = middleware.call(env_for(host: "preview-#{job.id}.lvh.me"))
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

      env = env_for(host: "preview-#{job.id}.lvh.me", path: "/submit", method: "POST", body: "field=value")
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
      status, _, _ = middleware.call(env_for(host: "preview-#{job.id}.lvh.me:3000"))
      expect(status).to eq(200)
    end
  end
end
