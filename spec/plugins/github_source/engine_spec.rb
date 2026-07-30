require "rails_helper"

RSpec.describe SyrusGithubSource::Engine do
  it "registers the GitHub input source provider" do
    expect(Syrus::PluginRegistry.providers_for(:input_source)).to include(InputSources::Github)
  end
end
