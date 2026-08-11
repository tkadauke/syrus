require "rails_helper"

RSpec.describe Discord::Client do
  let(:token) { "test-bot-token" }
  subject(:client) { described_class.new(token: token) }

  describe "#create_dm_channel" do
    it "posts to the correct channels endpoint with the recipient id and returns the channel id" do
      stub_request(:post, "https://discord.com/api/v10/users/@me/channels")
        .with(
          body: JSON.generate({ "recipient_id" => 42 }),
          headers: { "Content-Type" => "application/json", "Authorization" => "Bot test-bot-token" }
        )
        .to_return(
          status: 200,
          body: JSON.generate({ "id" => "channel-1" }),
          headers: { "Content-Type" => "application/json" }
        )

      expect(client.create_dm_channel(42)).to eq("channel-1")
    end

    it "returns nil and logs on network error" do
      stub_request(:post, "https://discord.com/api/v10/users/@me/channels").to_raise(Net::OpenTimeout)

      expect(Rails.logger).to receive(:error).with(include("create_dm_channel"))
      expect(client.create_dm_channel(42)).to be_nil
    end
  end

  describe "#send_message" do
    it "posts to the correct messages endpoint with the content" do
      stub_request(:post, "https://discord.com/api/v10/channels/channel-1/messages")
        .with(
          body: JSON.generate({ "content" => "Hello" }),
          headers: { "Authorization" => "Bot test-bot-token" }
        )
        .to_return(
          status: 200,
          body: JSON.generate({ "id" => "message-1" }),
          headers: { "Content-Type" => "application/json" }
        )

      result = client.send_message(channel_id: "channel-1", content: "Hello")
      expect(result).to include("id" => "message-1")
    end

    it "returns nil and logs on network error" do
      stub_request(:post, "https://discord.com/api/v10/channels/channel-1/messages").to_raise(Net::OpenTimeout)

      expect(Rails.logger).to receive(:error).with(include("send_message"))
      expect(client.send_message(channel_id: "channel-1", content: "Hello")).to be_nil
    end
  end

  describe "#send_dm" do
    it "opens the DM channel then posts the message to it" do
      stub_request(:post, "https://discord.com/api/v10/users/@me/channels")
        .to_return(status: 200, body: JSON.generate({ "id" => "channel-1" }))
      stub_request(:post, "https://discord.com/api/v10/channels/channel-1/messages")
        .to_return(status: 200, body: JSON.generate({ "id" => "message-1" }))

      result = client.send_dm(user_id: 42, text: "Hi there")

      expect(result).to include("id" => "message-1")
      expect(WebMock).to have_requested(:post, "https://discord.com/api/v10/channels/channel-1/messages")
        .with(body: JSON.generate({ "content" => "Hi there" }))
    end

    it "returns nil without posting a message when the channel lookup fails" do
      stub_request(:post, "https://discord.com/api/v10/users/@me/channels")
        .to_return(status: 401, body: JSON.generate({ "message" => "Unauthorized" }))

      expect(client.send_dm(user_id: 42, text: "Hi there")).to be_nil
      expect(WebMock).not_to have_requested(:post, %r{/messages})
    end
  end
end
