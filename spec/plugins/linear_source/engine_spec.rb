require "rails_helper"

RSpec.describe SyrusLinearSource::Engine do
  it "registers the Linear input source provider" do
    expect(Syrus::PluginRegistry.providers_for(:input_source)).to include(InputSources::Linear)
  end
end
