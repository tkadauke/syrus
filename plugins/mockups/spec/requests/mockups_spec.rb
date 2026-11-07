require "rails_helper"

RSpec.describe "API: /api/v1/app/mockups", type: :request do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user(email_address: "other@example.com") }

  def mockup_for(owner, title: "Nav sketch", files: { "index.html" => "<h1>hi</h1>" })
    chat = ChatSession.create!(user: owner, title: "Planning")
    panel = PreviewPanel::Service.open!(chat_session: chat, title: title, files: files)
    Mockups::Mockup.record_publish!(panel: panel, user: owner, title: title, chat_session: chat)
  end

  it "lists the current user's mockups with the filter schema behind the bar" do
    mockup = mockup_for(user)
    sign_in_as(user)

    get "/api/v1/app/mockups"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["mockups"].map { |m| m["slug"] }).to eq([ mockup.slug ])
    expect(body["filter_schema"].map { |f| f["field"] }).to include("title", "created_at", "updated_at")
  end

  it "filters by title through the chip bar" do
    mockup_for(user, title: "Nav sketch")
    mockup_for(user, title: "Settings page")
    sign_in_as(user)

    tree = { "and" => [ { "field" => "title", "op" => "contains", "value" => "Settings" } ] }
    # `q` is base64url-encoded, which is also what the chip bar sends.
    get "/api/v1/app/mockups?#{Filters::QueryParam::PARAM_NAME}=#{Filters::QueryParam.encode(tree)}"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["mockups"].map { |m| m["title"] }).to eq([ "Settings page" ])
    # Returned so the chip bar can render the filter that is actually applied,
    # instead of showing an empty bar over filtered results.
    expect(body["filter"].to_s).to include("title")
  end

  # A mockup is visible to whoever can see the panel behind it -- the same rule
  # the chat sidebar applies, not a looser one.
  it "hides a mockup whose panel the viewer cannot reach" do
    other = mockup_for(other_user)
    sign_in_as(user)

    get "/api/v1/app/mockups"
    expect(JSON.parse(response.body)["mockups"]).to be_empty

    get "/api/v1/app/mockups/#{other.slug}"
    expect(response).to have_http_status(:not_found)
  end

  it "shows a mockup with the panel payload the preview renders" do
    mockup = mockup_for(user)
    sign_in_as(user)

    get "/api/v1/app/mockups/#{mockup.slug}"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    panel = body["panel"]
    expect(panel["app_file_base_path"]).to eq("/api/v1/app/preview_panels/#{mockup.preview_panel_id}/files")
    expect(panel["app_visibility_path"]).to eq("/api/v1/app/preview_panels/#{mockup.preview_panel_id}")
    expect(body.dig("mockup", "chat_path")).to eq("/chats/#{mockup.chat_session_id}")
    expect(panel["entry_viewer_kind"]).to eq("html")
    expect(panel["versions"].size).to eq(1)
  end

  it "returns full panel history only when requested" do
    mockup = mockup_for(user)
    first_version_id = mockup.preview_panel.current_version.id
    PreviewPanel::Service.new(mockup.preview_panel).update!(files: { "index.html" => "new" })
    sign_in_as(user)

    get "/api/v1/app/mockups/#{mockup.slug}?versions=all"

    expect(JSON.parse(response.body).dig("panel", "versions").map { |version| version["id"] }).to eq(
      [ mockup.preview_panel.reload.current_version.id, first_version_id ]
    )
  end

  it "omits the filter schema after the first page and does not return an exact total" do
    mockup_for(user)
    sign_in_as(user)

    get "/api/v1/app/mockups?page=2"

    body = JSON.parse(response.body)
    expect(body["filter_schema"]).to be_nil
    expect(body["pagination"]).not_to have_key("total")
  end

  it "serves the filter schema independently for clients that cache it" do
    sign_in_as(user)

    get "/api/v1/app/mockups?schema=1"

    body = JSON.parse(response.body)
    expect(body.keys).to contain_exactly("v", "filter_schema")
    expect(body["v"]).to eq(ApiVersion::CURRENT)
    expect(body["filter_schema"].map { |field| field["field"] }).to include("title")
  end

  it "keeps a mockup viewable after its chat panel is closed" do
    mockup = mockup_for(user, files: { "index.html" => "<h1>saved mockup</h1>" })
    mockup.preview_panel.update!(state: "closed")
    sign_in_as(user)

    get "/api/v1/app/mockups/#{mockup.slug}"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("panel", "url")).to be_present
    proxy = PreviewProxyMiddleware.new(->(_env) { [ 200, {}, [ "upstream" ] ] })
    base_domain = ENV.fetch("SYRUS_PREVIEW_BASE_DOMAIN", "lvh.me")
    token = PreviewPanel::AccessToken.issue(mockup.preview_panel)
    env = Rack::MockRequest.env_for(
      "http://preview-panel-#{mockup.preview_panel_id}.#{base_domain}/?token=#{Rack::Utils.escape(token)}"
    )
    env["HTTP_HOST"] = "preview-panel-#{mockup.preview_panel_id}.#{base_domain}"
    status, _, body = proxy.call(env)
    expect(status).to eq(200)
    expect(body.join).to eq("<h1>saved mockup</h1>")
  end

  it "accepts a bare id as well as the slug" do
    mockup = mockup_for(user)
    sign_in_as(user)

    get "/api/v1/app/mockups/#{mockup.id}"

    expect(response).to have_http_status(:ok)
  end
end
