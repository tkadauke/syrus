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
    Factories.repository

    expect { Admin::PluginDisableGuard.ensure_disableable!(manifest) }
      .to raise_error(Admin::PluginDisableGuard::Blocked, /input sources|source-control/)
  end

  it "registers the GitHub source-control provider" do
    expect(Syrus::PluginRegistry.providers_for(:source_control_provider)).to include(SourceControl::GithubOperations)
  end
end
