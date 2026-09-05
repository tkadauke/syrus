require "rails_helper"

# Panels used to be reachable only through the chat they were opened in, so a
# plugin listing them on its own page had nowhere to fetch content from. The
# access rule is unchanged: you can see a panel if you can see its chat.
RSpec.describe "API: /api/v1/app/preview_panels", type: :request do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user(email_address: "other@example.com") }

  def panel_for(owner, files: { "index.html" => "<h1>hi</h1>" })
    chat = ChatSession.create!(user: owner, title: "Planning")
    PreviewPanel::Service.open!(chat_session: chat, title: "Sketch", files: files)
  end

  it "serves the panel payload outside any chat" do
    panel = panel_for(user)
    sign_in_as(user)

    get "/api/v1/app/preview_panels/#{panel.id}"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["app_file_base_path"]).to eq("/api/v1/app/preview_panels/#{panel.id}/files")
    expect(body["entry_viewer_kind"]).to eq("html")
  end

  it "serves a file" do
    panel = panel_for(user)
    sign_in_as(user)

    get "/api/v1/app/preview_panels/#{panel.id}/files/index.html?raw=1"

    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("<h1>hi</h1>")
  end

  it "issues an access token for a private panel" do
    panel = panel_for(user)
    sign_in_as(user)

    post "/api/v1/app/preview_panels/#{panel.id}/token"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["token"]).to be_present
  end

  it "refuses a token for a public panel, which needs none" do
    panel = panel_for(user)
    panel.update!(visibility: "public")
    sign_in_as(user)

    post "/api/v1/app/preview_panels/#{panel.id}/token"

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "does not expose a panel from a chat the viewer cannot see" do
    panel = panel_for(other_user)
    sign_in_as(user)

    get "/api/v1/app/preview_panels/#{panel.id}"
    expect(response).to have_http_status(:not_found)

    get "/api/v1/app/preview_panels/#{panel.id}/files/index.html?raw=1"
    expect(response).to have_http_status(:not_found)
  end

  it "404s a missing version rather than serving the current one" do
    panel = panel_for(user)
    sign_in_as(user)

    get "/api/v1/app/preview_panels/#{panel.id}/files/index.html?v=999999"

    expect(response).to have_http_status(:not_found)
  end
end
