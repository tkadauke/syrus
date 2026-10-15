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
      expect(client.run_outcome).to eq(:fatal_close)
      expect(client.instance_variable_get(:@should_reconnect)).to be false
    end

    it "reconnects in-process for resumable close codes when a session exists" do
      client.instance_variable_set(:@session_id, "session-1")

      client.send(:handle_close, CloseEvent.new(code: 4000, reason: "Unknown error"))

      expect(client).not_to be_fatal_close
      expect(client.run_outcome).to eq(:resumable_close)
      expect(client.instance_variable_get(:@should_reconnect)).to be true
    end

    it "does not reconnect in-process for resumable startup closes before a session exists" do
      client.send(:handle_close, CloseEvent.new(code: 1006, reason: "Abnormal closure"))

      expect(client).not_to be_fatal_close
      expect(client.run_outcome).to eq(:startup_failure)
      expect(client.instance_variable_get(:@should_reconnect)).to be false
    end

    it "marks ordinary post-session closes as backoff-resetting" do
      client.instance_variable_set(:@session_id, "session-1")

      client.send(:handle_close, CloseEvent.new(code: 1000, reason: "Normal closure"))

      expect(client.run_outcome).to eq(:closed)
      expect(client).to be_reset_reconnect_backoff
    end

    it "does not let a normal close event hide an explicit Gateway reconnect request" do
      driver = instance_double(WebSocket::Driver::Client, close: nil)
      client.instance_variable_set(:@driver, driver)
      client.instance_variable_set(:@session_id, "session-1")

      client.send(:handle_frame, JSON.generate("op" => described_class::OP_RECONNECT, "d" => nil))
      client.send(:handle_close, CloseEvent.new(code: 1000, reason: "Normal closure"))

      expect(client.run_outcome).to eq(:gateway_reconnect_requested)
      expect(client).not_to be_reset_reconnect_backoff
    end
  end
end
