require "rails_helper"

RSpec.describe ChatChannel do
  it "routes in_syrus repository config to the in-Syrus channel" do
    repository = Factories.repository(allow_operator_chat: "in_syrus")

    expect(described_class.for(repository)).to be_a(ChatChannel::InSyrus)
  end

  it "routes telegram repository config to the Telegram channel" do
    repository = Factories.repository(allow_operator_chat: "telegram")

    expect(described_class.for(repository)).to be_a(ChatChannel::Telegram)
  end

  it "rejects disabled operator chat" do
    repository = Factories.repository(allow_operator_chat: "disabled")

    expect { described_class.for(repository) }
      .to raise_error(ChatChannel::ConfigurationError, /operator chat is not enabled/)
  end
end
