require "rails_helper"
require "zlib"

RSpec.describe "SPA shell", type: :request do
  def with_public_asset(relative_path, body)
    path = Rails.public_path.join(relative_path)
    FileUtils.mkdir_p(path.dirname)
    path.binwrite(body)
    yield path
  ensure
    [ path, Pathname.new("#{path}.br"), Pathname.new("#{path}.gz") ].each { |asset_path| asset_path.delete if asset_path&.exist? }
  end

  def gzip(content)
    StringIO.new.tap do |io|
      Zlib::GzipWriter.wrap(io) { |writer| writer.write(content) }
    end.string
  end

  def response_etag
    response.headers["ETag"] || response.headers["etag"]
  end

  def frontend_app_routes
    source = Rails.root.join("app/frontend/routes/App.tsx").read
    route_table = source
      .split("const appRouteDefinitions: AppRouteDefinition[] = [", 2)
      .fetch(1)
      .split("\n]\n\nexport function App", 2)
      .fetch(0)

    route_table.scan(/path:\s*"([^"]+)"/).flatten.reject { |route| route.include?("*") }.uniq
  end

  def installed_plugin_spa_routes
    Syrus::PluginRegistry.all_plugins.flat_map do |manifest|
      metadata = manifest.metadata.with_indifferent_access
      Array(metadata[:routes]).filter_map do |route|
        route = route.to_h.symbolize_keys
        path = route[:path].to_s
        controller = route[:controller].to_s
        path if controller == "spa#show" && path.start_with?("/")
      end
    end
  end

  def representative_frontend_path(route)
    route.gsub(/:([A-Za-z0-9_]+)/) do
      case Regexp.last_match(1).downcase
      when "tab"
        "active"
      when "token"
        "sample-token"
      else
        "123"
      end
    end
  end

  it "serves precompressed SPA assets when the browser advertises support and varies shared caches by encoding" do
    with_public_asset("assets/spa-compressed-fixture.js", "console.log('plain')") do |path|
      Pathname.new("#{path}.br").binwrite("brotli body")
      Pathname.new("#{path}.gz").binwrite(gzip("gzip body"))

      get "/assets/spa-compressed-fixture.js", headers: { "Accept-Encoding" => "gzip, br" }

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Encoding"]).to eq("br")
      expect(response.headers["Vary"].downcase).to eq("accept-encoding")
      expect(response.headers["ETag"] || response.headers["etag"]).to be_present
      expect(response.headers["Content-Length"].to_i).to eq("brotli body".bytesize)
      expect(response.body).to eq("brotli body")
    end
  end

  it "honors conditional GETs for precompressed SPA asset variants" do
    with_public_asset("assets/spa-conditional-fixture.js", "console.log('plain')") do |path|
      Pathname.new("#{path}.br").binwrite("brotli body")

      get "/assets/spa-conditional-fixture.js", headers: { "Accept-Encoding" => "br" }
      etag = response_etag

      get "/assets/spa-conditional-fixture.js", headers: { "Accept-Encoding" => "br", "If-None-Match" => etag }

      expect(response).to have_http_status(:not_modified)
      expect(response_etag).to eq(etag)
      expect(response.body).to be_empty
    end
  end

  it "does not serve gzip when the browser explicitly refuses gzip through q-values" do
    with_public_asset("assets/spa-gzip-refused-fixture.js", "console.log('plain')") do |path|
      gz_body = gzip("gzip body")
      Pathname.new("#{path}.gz").binwrite(gz_body)

      get "/assets/spa-gzip-refused-fixture.js", headers: { "Accept-Encoding" => "gzip;q=0, *;q=1" }

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Encoding"]).to be_nil
      expect(response.body).to eq("console.log('plain')")

      get "/assets/spa-gzip-refused-fixture.js", headers: { "Accept-Encoding" => "gzip" }

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Encoding"]).to eq("gzip")
      expect(response.body.b).to eq(gz_body.b)
    end
  end

  it "serves SPA assets uncompressed when the browser does not advertise encoded support" do
    with_public_asset("assets/spa-uncompressed-fixture.js", "console.log('plain')") do |path|
      Pathname.new("#{path}.br").binwrite("brotli body")
      Pathname.new("#{path}.gz").binwrite(gzip("gzip body"))

      get "/assets/spa-uncompressed-fixture.js"

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Encoding"]).to be_nil
      expect(response.headers["Vary"].downcase).to eq("accept-encoding")
      expect(response.body).to eq("console.log('plain')")
    end
  end

  it "uses the normal HTML authentication flow when signed out" do
    Factories.user

    get app_shell_path

    expect(response).to redirect_to(new_session_path)
  end

  it "serves the public root through the SPA shell when signed out" do
    Factories.user

    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
    expect(response.body).to include('"current_user":null')
  end

  it "prevents browser caching of the SPA shell" do
    Factories.user

    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.headers["X-Syrus-Revision"]).to eq(SyrusVersion.current)
  end

  it "does not version content-hashed SPA assets, but still versions unhashed assets" do
    allow(SyrusVersion).to receive(:current).and_return("cache-sha")
    user = Factories.user
    sign_in_as(user)

    get app_shell_path

    expect(response).to have_http_status(:ok)
    css_paths = response.body.scan(/<link rel="stylesheet" href="([^"]+)"/).flatten
    js_paths = response.body.scan(/<script src="([^"]+)" type="module"><\/script>/).flatten
    expect(css_paths).not_to be_empty
    expect(css_paths).to include(a_string_matching(%r{\A/assets/.+-[0-9a-f]{8,}\.css\z}))
    expect(css_paths).not_to include(a_string_including("/assets/assets/"))
    expect(css_paths).not_to include(a_string_including("?v=cache-sha"))
    expect(js_paths).to include("/assets/spa-test.js?v=cache-sha")
  end

  it "keeps unchanged content-hashed SPA asset URLs stable across deploy revisions" do
    user = Factories.user
    sign_in_as(user)

    allow(SyrusVersion).to receive(:current).and_return("first-sha")
    get app_shell_path
    first_css_paths = response.body.scan(/<link rel="stylesheet" href="([^"]+)"/).flatten

    allow(SyrusVersion).to receive(:current).and_return("second-sha")
    get app_shell_path
    second_css_paths = response.body.scan(/<link rel="stylesheet" href="([^"]+)"/).flatten

    first_hashed_css_paths = first_css_paths.grep(%r{\A/assets/.+-[0-9a-f]{8,}\.css\z})
    second_hashed_css_paths = second_css_paths.grep(%r{\A/assets/.+-[0-9a-f]{8,}\.css\z})

    expect(first_hashed_css_paths).not_to be_empty
    expect(second_hashed_css_paths).to eq(first_hashed_css_paths)
  end

  it "installs startup diagnostics before the SPA module entrypoint" do
    allow(SyrusVersion).to receive(:current).and_return("startup-sha")
    user = Factories.user
    sign_in_as(user)

    get app_shell_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('<meta name="syrus-app-revision" content="startup-sha">')
    expect(response.body).to include('<meta name="syrus-asset-revision" content="startup-sha">')
    diagnostics_index = response.body.index('id="syrus-startup-diagnostics"')
    module_index = response.body.index('type="module"')
    expect(diagnostics_index).to be_present
    expect(module_index).to be_present
    expect(diagnostics_index).to be < module_index
    expect(response.body).to include('window.SyrusStartupDiagnostics')
    expect(response.body).to include('/api/v1/app/performance_events')
    expect(response.body).to include('/api/v1/app/browser_errors')
    expect(response.body).to include('StartupWatchdog')
    expect(response.body).to include('StartupResourceError')
    expect(response.body).to include('navigator.standalone')
    expect(response.body).to include('display-mode: standalone')
  end

  it "renders a visible shell loading state before the SPA bundle executes" do
    user = Factories.user
    sign_in_as(user)

    get app_shell_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-startup-status"')
    expect(response.body).to include('data-startup-state="loading"')
    expect(response.body).to include("Loading Syrus")
    expect(response.body).to include("Loading the app.")
    expect(response.body).to include('href="/app-shell" data-syrus-startup-retry hidden>Retry</a>')
    expect(response.body.index('id="syrus-startup-status"')).to be < response.body.index('id="syrus-spa-root"')
  end

  it "serves the authenticated app shell at root when signed in" do
    user = Factories.user(email_address: "root-operator@example.com")
    sign_in_as(user)

    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
    expect(response.body).to include("root-operator@example.com")
    expect(response.body).not_to include('"current_user":null')
  end

  it "serves public auth routes through the SPA shell" do
    Factories.user

    [ new_session_path, new_password_path ].each do |path|
      get path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')
      expect(response.body).to include('"current_user":null')
      expect(response.body).not_to include("&quot;current_user&quot;")
    end
  end

  it "serves password reset routes through the SPA shell" do
    user = Factories.user

    get edit_password_path(user.password_reset_token)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
  end

  it "renders the React mount for signed-in users" do
    user = Factories.user
    sign_in_as(user)

    get app_shell_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
    expect(response.body).to include('id="syrus-bootstrap-data"')
    expect(response.body).to include(user.email_address)
    expect(response.body).to include("<title>Syrus</title>")
  end

  it "advertises the branded favicon and PWA manifest assets" do
    user = Factories.user
    sign_in_as(user)

    get app_shell_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('<meta name="apple-mobile-web-app-title" content="Syrus">')
    expect(response.body).to include('<meta name="apple-mobile-web-app-status-bar-style" content="default">')
    expect(response.body).to include('<meta name="theme-color" content="#c9704b">')
    expect(response.body).to include('<link rel="icon" href="/icon.png?v=2" type="image/png">')
    expect(response.body).to include('<link rel="apple-touch-icon" href="/apple-touch-icon.png?v=2">')
    expect(response.body).to include('<link rel="manifest" href="/manifest.json">')
  end

  it "serves PWA icon sizes from distinct branded assets" do
    get pwa_manifest_path

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    manifest = JSON.parse(response.body)
    expect(manifest.fetch("icons")).to contain_exactly(
      include("src" => "/icon-192.png", "type" => "image/png", "sizes" => "192x192"),
      include("src" => "/icon-512.png", "type" => "image/png", "sizes" => "512x512", "purpose" => "maskable")
    )
    expect(manifest.fetch("theme_color")).to eq("#c9704b")
    expect(manifest.fetch("background_color")).to eq("#f7ead5")
  end

  it "serves canonical Apple touch icon probes as PNG assets instead of the SPA shell" do
    [ apple_touch_icon_path, apple_touch_icon_precomposed_path ].each do |path|
      get path

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/png")
      expect(response.body).to start_with("\x89PNG\r\n\x1A\n".b)
      expect(response.body).not_to include('id="syrus-spa-root"')
    end
  end

  it "serves nested React routes through the SPA shell" do
    user = Factories.user
    sign_in_as(user)

    get "/app-shell/admin"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
  end

  it "serves canonical dashboard routes through the SPA shell" do
    user = Factories.user
    sign_in_as(user)

    [ root_path, dashboard_path, dashboard_epics_path, dashboard_jobs_path, dashboard_workflows_path ].each do |path|
      get path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')
      expect(response.body).to include('id="syrus-bootstrap-data"')
    end
  end

  it "serves top-level app routes through the SPA shell" do
    user = Factories.user
    sign_in_as(user)

    # design_docs is a plugin page and is covered by the "routes every React
    # app route" example below; core no longer hand-writes its URLs, so there
    # are no named helpers for them here.
    [ notifications_path, memories_path, search_chats_path ].each do |path|
      get path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')
      expect(response.body).to include('id="syrus-bootstrap-data"')
    end
  end

  it "keeps normal one-segment routes ahead of root-level slug redirects" do
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
    user = Factories.user
    sign_in_as(user)

    get "/jobs"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')

    get "/epics"
    expect(response).to redirect_to("/dashboard/epics")

    get "/briefing"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')

    get "/up"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('id="syrus-spa-root"')

    get "/not-a-slug"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
  end

  # Every path a plugin's sidebar page declares has to reach spa#show, or a
  # hard reload / direct navigation renders the bare bootstrap shell instead of
  # the page -- which is what /design_docs/22 did, because the plugin declared
  # only the index path while its component had always branched on params.id.
  # There is no plugin-specific derivation left to guard here: the blanket
  # wildcard below serves any path the React router owns, declared plugin or
  # not, so this is now the same assertion as "routes every React app route".
  it "routes every React app route through the SPA shell" do
    (frontend_app_routes + installed_plugin_spa_routes).uniq.each do |route|
      path = representative_frontend_path(route)
      recognized = Rails.application.routes.recognize_path(path, method: :get)

      expect(recognized).to include(controller: "spa", action: "show"), "expected #{route} (sample #{path}) to route to spa#show"
    end
  end

  it "serves every registered repo_page_tab provider's tab paths through the SPA shell on hard reload" do
    owner = Factories.user
    repository = Factories.repository(user: owner)
    sign_in_as(owner)

    tabs = Syrus::PluginRegistry.providers_for(:repo_page_tab).flat_map do |provider|
      Array(provider.repo_page_tabs(repository: repository, user: owner))
    end

    expect(tabs).not_to be_empty

    tabs.each do |tab|
      tab = tab.to_h.symbolize_keys
      path = tab.fetch(:path)

      get path

      expect(response).to have_http_status(:ok), "expected repo_page_tab #{tab[:id]} path #{path} to route to the SPA shell, not a 404"
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  it "serves the admin performance route through the SPA shell" do
    user = Factories.user(admin: true)
    sign_in_as(user)

    get "/admin/performance"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
    expect(response.body).to include('id="syrus-bootstrap-data"')
  end

  it "serves the operator-scoped agent_activity route through the SPA shell for any signed-in user" do
    user = Factories.user(admin: false)
    sign_in_as(user)

    get "/agent_activity"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
  end

  it "serves the admin-wide agent_activity route through the SPA shell, gated to admins" do
    user = Factories.user(admin: true)
    sign_in_as(user)

    get "/admin/agent_activity"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
  end

  it "does not route unmatched API paths through the SPA shell" do
    expect {
      Rails.application.routes.recognize_path("/api/nope", method: :get)
    }.to raise_error(ActionController::RoutingError)
  end

  # Active Storage's own config/routes.rb loads AFTER this file finishes (see
  # Rails.application.routes_reloader.paths), so its GET routes land BEHIND
  # the blanket wildcard in the final route set rather than in front of it.
  # Without the "/rails" exclusion the wildcard would win first and serve the
  # SPA shell for a blob download instead of losing to it "by declaration
  # order" the way every other route in this file does.
  it "does not route Active Storage paths through the SPA shell" do
    recognized = Rails.application.routes.recognize_path("/rails/active_storage/blobs/redirect/abc/file.png", method: :get)

    expect(recognized[:controller]).to eq("active_storage/blobs/redirect")
  end

  it "requires authentication for canonical dashboard routes" do
    Factories.user

    get dashboard_jobs_path

    expect(response).to redirect_to(new_session_path)
  end

  it "requires admin access for admin SPA routes" do
    Factories.user
    user = Factories.user
    sign_in_as(user)

    get "/app-shell/admin"

    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to match(/admin/i)
  end

  it "redirects to root instead of a bare 404 for an inaccessible chat" do
    owner = Factories.user
    chat = ChatSession.create!(user: owner)
    user = Factories.user
    sign_in_as(user)

    get chat_path(chat)

    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to match(/no longer available/i)
  end

  it "redirects to root instead of a bare 404 for a soft-deleted chat" do
    user = Factories.user
    chat = ChatSession.create!(user: user)
    chat.soft_delete_by!(user)
    sign_in_as(user)

    get chat_path(chat)

    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to match(/no longer available/i)
  end

  it "redirects to root instead of a bare 404 for a nonexistent chat" do
    user = Factories.user
    sign_in_as(user)

    get chat_path(999_999)

    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to match(/no longer available/i)
  end

  it "requires admin access for non-/admin admin SPA routes" do
    Factories.user
    user = Factories.user
    sign_in_as(user)

    [ "/app-shell/invitations", "/app-shell/settings/edit", "/app-shell/admin/github_app/register", "/app-shell/admin/github_app/confirm" ].each do |path|
      get path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to match(/admin/i)
    end
  end
end
