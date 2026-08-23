require "rails_helper"

RSpec.describe Syrus::Plugin::WorkspaceTab do
  let(:provider) { Class.new { include Syrus::Plugin::WorkspaceTab } }

  it "raises NotImplementedError for workspace_tabs by default" do
    expect { provider.workspace_tabs }.to raise_error(NotImplementedError, /must implement \.workspace_tabs/)
  end

  it "defaults available_for? to true" do
    expect(provider.available_for?(double("chat_session"))).to be(true)
  end

  it "extends including classes with the class methods" do
    expect(provider).to respond_to(:workspace_tabs, :available_for?)
  end
end
