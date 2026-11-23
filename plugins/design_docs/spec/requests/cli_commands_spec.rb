require "rails_helper"

RSpec.describe "Design Docs CLI commands", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before do
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "design_docs", version: "1.0.0", events: {
      "design_doc.upserted" => :async,
      "design_doc.deleted" => :async
    }, cli_commands: [
      { path: %w[docs list], summary: "List design docs", handler: "DesignDocs::Cli::List", flags: [ { name: "repo" } ] },
      { path: %w[docs show], summary: "Show a design doc", handler: "DesignDocs::Cli::Show", arguments: [ { name: "DOC-ID", required: true } ] }
    ])
    PluginRecord.find_by!(name: "design_docs").update!(enabled: true)
    sign_in_as(user)
  end

  after { Syrus::PluginRegistry.reset! }

  it "lists visible design docs in the former table shape and supports repository scoping" do
    included = DesignDocs::DesignDoc.create!(owner_user: user, title: "Included", markdown: "Body")
    included.repositories << repository
    DesignDocs::DesignDoc.create!(owner_user: user, title: "Excluded", markdown: "Body")

    post "/api/v1/app/cli_commands/execute", params: {
      plugin: "design_docs", path: %w[docs list], args: [], flags: { repo: repository.slug }
    }, as: :json

    expect(response).to have_http_status(:ok)
    result = response.parsed_body.fetch("result")
    expect(result.fetch("columns")).to eq(%w[DOC TITLE STATE VISIBILITY OWNER REPOS UPDATED])
    expect(result.fetch("rows").map { |row| row.fetch(1) }).to eq([ "Included" ])
  end

  it "shows a design doc by its prefixed identifier with the rendered body shape" do
    design_doc = DesignDocs::DesignDoc.create!(owner_user: user, title: "Command API", markdown: "# Body")

    post "/api/v1/app/cli_commands/execute", params: {
      plugin: "design_docs", path: %w[docs show], args: [ design_doc.display_id ], flags: {}
    }, as: :json

    expect(response).to have_http_status(:ok)
    text = response.parsed_body.dig("result", "text")
    expect(text).to include("#{design_doc.display_id} · Command API", "State: draft", "# Body")
  end
end
