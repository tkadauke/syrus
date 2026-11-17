require "rails_helper"

RSpec.describe "Design Docs CLI commands", type: :request do
  let!(:user) { Factories.user(admin: false) }
  let!(:other_user) { Factories.user(admin: false) }
  let!(:repository) { Factories.repository }

  before do
    PluginRecord.find_by!(name: "design_docs").update!(enabled: true)
    repository.repository_memberships.create!(user: user, role: "read")
    sign_in_as(user)
  end

  def create_doc(owner:, title:, visibility: "private", repositories: [])
    result = DesignDocs::Create.call(
      user: owner,
      attributes: { title: title, markdown: "# Body\n\nContent.", visibility: visibility, repository_ids: repositories.map(&:id) }
    )
    result.design_doc
  end

  def execute(path, args: [], flags: {})
    post "/api/v1/app/cli_commands/execute",
      params: { plugin: "design_docs", path: path, args: args, flags: flags }, as: :json
  end

  it "publishes the established docs command paths in the catalog" do
    get "/api/v1/app/cli_commands"

    paths = response.parsed_body.fetch("commands").filter_map do |command|
      command.fetch("path") if command.fetch("plugin") == "design_docs"
    end
    expect(paths).to contain_exactly(%w[docs list], %w[docs show])
  end

  it "lists visible docs and supports explicit repository scoping" do
    visible = create_doc(owner: user, title: "Visible", repositories: [ repository ])
    create_doc(owner: other_user, title: "Hidden")

    execute(%w[docs list], flags: { repo: repository.slug })

    expect(response).to have_http_status(:ok), response.body
    result = response.parsed_body.fetch("result")
    expect(result.fetch("columns")).to eq(%w[DOC TITLE STATE VISIBILITY OWNER REPOS UPDATED])
    expect(result.fetch("rows")).to include(include(visible.display_id, "Visible", repository.slug))
    expect(response.body).not_to include("Hidden")
  end

  it "shows a visible doc by its DOC reference with rendered markdown" do
    design_doc = create_doc(owner: user, title: "Command Contract", repositories: [ repository ])

    execute(%w[docs show], args: [ design_doc.display_id ])

    expect(response).to have_http_status(:ok), response.body
    text = response.parsed_body.dig("result", "text")
    expect(text).to include("#{design_doc.display_id} · Command Contract", "Repositories: #{repository.slug}", "# Body", "Content.")
  end
end
