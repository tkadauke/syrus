require "rails_helper"

RSpec.describe TelegramClient do
  let(:token) { "test-bot-token" }
  subject(:client) { described_class.new(token: token) }

  describe "#get_updates" do
    it "requests the correct getUpdates endpoint with offset and timeout" do
      stub_request(:get, "https://api.telegram.org/bottest-bot-token/getUpdates")
        .with(query: { "offset" => "10", "timeout" => "25" })
        .to_return(
          status: 200,
          body: JSON.generate({ "ok" => true, "result" => [{ "update_id" => 10 }] }),
          headers: { "Content-Type" => "application/json" }
        )

      result = client.get_updates(offset: 10, timeout: 25)
      expect(result).to eq([{ "update_id" => 10 }])
    end

    it "raises when the Telegram API rejects the request" do
      stub_request(:get, "https://api.telegram.org/bottest-bot-token/getUpdates")
        .with(query: hash_including("offset" => "0"))
        .to_return(
          status: 200,
          body: JSON.generate({ "ok" => false, "description" => "Unauthorized" }),
          headers: { "Content-Type" => "application/json" }
        )

      expect { client.get_updates(offset: 0) }
        .to raise_error(TelegramClient::Error, "Unauthorized")
    end

    it "raises on network error" do
      stub_request(:get, "https://api.telegram.org/bottest-bot-token/getUpdates")
        .with(query: hash_including("offset" => "0"))
        .to_raise(Net::OpenTimeout)

      expect { client.get_updates(offset: 0) }.to raise_error(Net::OpenTimeout)
    end

    it "returns an empty array on timeout (empty result)" do
      stub_request(:get, "https://api.telegram.org/bottest-bot-token/getUpdates")
        .with(query: hash_including("offset" => "5"))
        .to_return(
          status: 200,
          body: JSON.generate({ "ok" => true, "result" => [] }),
          headers: { "Content-Type" => "application/json" }
        )

      expect(client.get_updates(offset: 5)).to eq([])
    end
  end

  describe "#send_message" do
    it "posts to the correct sendMessage endpoint with chat_id and text" do
      stub_request(:post, "https://api.telegram.org/bottest-bot-token/sendMessage")
        .with(
          body: JSON.generate({ "chat_id" => 42, "text" => "Hello" }),
          headers: { "Content-Type" => "application/json" }
        )
        .to_return(
          status: 200,
          body: JSON.generate({ "ok" => true, "result" => { "message_id" => 1 } }),
          headers: { "Content-Type" => "application/json" }
        )

      result = client.send_message(chat_id: 42, text: "Hello")
      expect(result).to include("ok" => true)
    end

    it "includes parse_mode when provided" do
      stub_request(:post, "https://api.telegram.org/bottest-bot-token/sendMessage")
        .with(body: JSON.generate({ "chat_id" => 42, "text" => "**bold**", "parse_mode" => "MarkdownV2" }))
        .to_return(
          status: 200,
          body: JSON.generate({ "ok" => true }),
          headers: { "Content-Type" => "application/json" }
        )

      client.send_message(chat_id: 42, text: "**bold**", parse_mode: "MarkdownV2")
    end

    it "returns nil and logs on network error" do
      stub_request(:post, "https://api.telegram.org/bottest-bot-token/sendMessage")
        .to_raise(Net::OpenTimeout)

      expect(Rails.logger).to receive(:error).with(include("send_message"))
      expect(client.send_message(chat_id: 42, text: "Hello")).to be_nil
    end
  end
end
