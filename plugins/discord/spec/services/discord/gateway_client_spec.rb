require "rails_helper"

RSpec.describe Discord::GatewayClient do
  subject(:client) { described_class.new(token: "bot-token") }

  CloseEvent = Struct.new(:code, :reason, keyword_init: true)

  describe "Gateway close handling" do
    it "records fatal close codes and does not reconnect" do
      client.instance_variable_set(:@session_id, "session-1")

      client.send(:handle_close, CloseEvent.new(code: 4014, reason: "Disallowed intents"))

      expect(client).to be_fatal_close
      expect(client.fatal_close_code).to eq(4014)
      expect(client.fatal_close_reason).to eq("Disallowed intents")
      expect(client.instance_variable_get(:@should_reconnect)).to be false
    end

    it "reconnects in-process for resumable close codes when a session exists" do
      client.instance_variable_set(:@session_id, "session-1")

      client.send(:handle_close, CloseEvent.new(code: 4000, reason: "Unknown error"))

      expect(client).not_to be_fatal_close
      expect(client.instance_variable_get(:@should_reconnect)).to be true
    end

    it "does not reconnect in-process for resumable startup closes before a session exists" do
      client.send(:handle_close, CloseEvent.new(code: 1006, reason: "Abnormal closure"))

      expect(client).not_to be_fatal_close
      expect(client.instance_variable_get(:@should_reconnect)).to be false
    end
  end
end
