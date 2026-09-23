require "rails_helper"

RSpec.describe Syrus::Plugin::WorkspaceGitTransport do
  let(:provider) { Class.new { include Syrus::Plugin::WorkspaceGitTransport } }

  it "raises NotImplementedError for .available_for? by default" do
    expect { provider.available_for?(double("repository")) }.to raise_error(NotImplementedError, /must implement \.available_for\?/)
  end

  it "raises NotImplementedError for .build by default" do
    expect { provider.build(repository: double("repository"), user: double("user")) }.to raise_error(NotImplementedError, /must implement \.build/)
  end

  it "raises NotImplementedError for #url by default" do
    expect { provider.new.url }.to raise_error(NotImplementedError, /must implement #url/)
  end

  it "defaults #env to an empty hash" do
    expect(provider.new.env).to eq({})
  end

  it "defaults #register! to a no-op" do
    expect(provider.new.register!).to be_nil
  end

  it "extends including classes with the class methods" do
    expect(provider).to respond_to(:available_for?, :build)
  end
end
