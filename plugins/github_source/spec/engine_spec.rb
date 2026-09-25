require "rails_helper"

RSpec.describe SyrusGithubSource::Engine do
  it "registers the GitHub input source provider" do
    expect(Syrus::PluginRegistry.providers_for(:input_source)).to include(InputSources::Github)
  end

  it "is disableable, and guarded by usage rather than by a hard flag" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "github_source" }

    expect(manifest).to be_present
    expect(manifest.disableable?).to be(true)
  end

  it "cannot be disabled while an input source still uses it" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "github_source" }
    input_source_scope = instance_double(ActiveRecord::Relation, count: 1)
    allow(InputSource).to receive(:where).with(type: InputSources::Github.name).and_return(input_source_scope)
    allow(Repository).to receive(:active).and_return([])

    expect { Admin::PluginDisableGuard.ensure_disableable!(manifest) }
      .to raise_error(Admin::PluginDisableGuard::Blocked, /input sources/)
  end

  it "registers the GitHub source-control provider" do
    expect(Syrus::PluginRegistry.providers_for(:source_control_provider)).to include(SourceControl::GithubOperations)
  end

  it "registers its GitHub API usage admin page" do
    expect(Syrus::PluginRegistry.providers_for(:admin_page)).to include(GithubSource::AdminPages)
    expect(GithubSource::AdminPages.admin_pages.first).to include(
      path: "/admin/github_api_usage",
      component: "github_source/AdminGithubApiUsage"
    )
  end

  it "does not register the removed issue comment endpoint" do
    expect {
      Rails.application.routes.recognize_path("/api/v1/app/repositories/1/issues/comment", method: :post)
    }.to raise_error(ActionController::RoutingError)
  end
end
