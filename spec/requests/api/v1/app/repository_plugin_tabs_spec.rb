require "rails_helper"

RSpec.describe "API: /api/v1/app/repositories/:repository_id/plugin_tabs", type: :request do
  let(:owner) { Factories.user(email_address: "owner@example.com") }
  let(:repository) { Factories.repository(user: owner) }

  def parse_body = JSON.parse(response.body)

  def register_repo_page_tab_provider
    provider = Class.new do
      include Syrus::Plugin::RepoPageTab

      def self.repo_page_tabs(repository:, user:)
        [
          {
            id: "git_history.git_history",
            label: "Git History",
            label_key: "git_history:nav_git_history",
            path: "/repositories/#{repository.id}/plugin/git_history",
            paths: [ "/repositories/#{repository.id}/plugin/git_history" ],
            component: "git_history/GitHistory",
            order: 40
          }
        ]
      end
    end
    Syrus::PluginRegistry.register(name: "tab-plugin", version: "0.1.0", provides: { repo_page_tab: provider })
  end

  after { Syrus::PluginRegistry.reset! }

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/repositories/#{repository.id}/plugin_tabs"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "404s for a repository the signed-in user cannot access" do
    unrelated_user = Factories.user(email_address: "unrelated@example.com")
    sign_in_as(unrelated_user)

    get "/api/v1/app/repositories/#{repository.id}/plugin_tabs"

    expect(response).to have_http_status(:not_found)
  end

  it "returns repo page tabs from enabled plugins for the repository owner" do
    register_repo_page_tab_provider
    sign_in_as(owner)

    get "/api/v1/app/repositories/#{repository.id}/plugin_tabs"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("tabs")).to contain_exactly(
      include(
        "id" => "git_history.git_history",
        "label" => "Git History",
        "label_key" => "git_history:nav_git_history",
        "path" => "/repositories/#{repository.id}/plugin/git_history",
        "paths" => [ "/repositories/#{repository.id}/plugin/git_history" ],
        "component" => "git_history/GitHistory",
        "order" => 40
      )
    )
  end

  it "returns repo page tabs for a RepositoryMembership collaborator" do
    register_repo_page_tab_provider
    collaborator = Factories.user(email_address: "collaborator@example.com")
    repository.repository_memberships.create!(user: collaborator, role: "collaborator")
    sign_in_as(collaborator)

    get "/api/v1/app/repositories/#{repository.id}/plugin_tabs"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("tabs").map { |tab| tab["id"] }).to include("git_history.git_history")
  end

  it "omits repo page tabs from disabled plugins" do
    register_repo_page_tab_provider
    PluginRecord.find_by!(name: "tab-plugin").update!(enabled: false)
    sign_in_as(owner)

    get "/api/v1/app/repositories/#{repository.id}/plugin_tabs"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq("tabs" => [])
  end
end
