require "rails_helper"

RSpec.describe "Content-Security-Policy", type: :request do
  it "sends a locked-down policy on the SPA shell, with a nonce for the inline theme script" do
    get "/"

    header = response.headers["Content-Security-Policy"]
    expect(header).to be_present
    expect(header).to include("default-src 'self'")
    expect(header).to include("object-src 'none'")
    expect(header).to include("frame-ancestors 'self'")
    expect(header).to match(/script-src 'self' 'wasm-unsafe-eval' 'nonce-[^']+'/)

    nonce = header[/script-src 'self' 'wasm-unsafe-eval' 'nonce-([^']+)'/, 1]
    expect(nonce).to be_present
    expect(response.body).to include(%(nonce="#{nonce}"))
  end

  it "allows WebAssembly instantiation for the Shiki syntax highlighter without broadly permitting eval" do
    get "/"

    header = response.headers["Content-Security-Policy"]
    expect(header).to include("'wasm-unsafe-eval'")
    expect(header).not_to include("'unsafe-eval'")
  end

  it "allows embedding the preview panel base domain in frame-src" do
    get "/"

    header = response.headers["Content-Security-Policy"]
    expect(header).to include("frame-src 'self' https://*.lvh.me http://*.lvh.me")
  end

  it "does not send a CSP header on the GitHub App manifest bounce page, which posts cross-origin to github.com" do
    admin = Factories.user
    sign_in_as(admin)
    get "/api/v1/app/admin/github_app/register"
    state = Rack::Utils.parse_query(URI.parse(JSON.parse(response.body).fetch("bounce_url")).query).fetch("state")
    reset!

    get "/admin/github_app/manifest", params: { state: state }

    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Security-Policy"]).to be_nil
  end
end
