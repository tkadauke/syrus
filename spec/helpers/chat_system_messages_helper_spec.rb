require "rails_helper"

RSpec.describe ChatSystemMessagesHelper, type: :helper do
  describe "#render_chat_system_message" do
    it "renders Claude result lines as compact run summaries" do
      html = helper.render_chat_system_message(
        "[result] subtype=success, is_error=false, turns=4, duration_ms=170223, total_cost_usd=0.37236969999999997"
      )
      text = Nokogiri::HTML.fragment(html).text.squish

      expect(text).to include("Done")
      expect(text).to include("Agent run succeeded")
      expect(text).to include("4 turns")
      expect(text).to include("2.8m")
      expect(text).to include("$0.37")
      expect(text).not_to include("0.37236969999999997")
    end

    it "renders failed result lines with the error subtype" do
      html = helper.render_chat_system_message(
        "[result] subtype=error_max_turns, is_error=true, turns=50, duration_ms=1200"
      )
      text = Nokogiri::HTML.fragment(html).text.squish

      expect(text).to include("Failed")
      expect(text).to include("Agent run failed: Error max turns")
      expect(text).to include("1.2s")
    end

    it "renders MCP server status lines as connection summaries" do
      html = helper.render_chat_system_message("[mcp_servers] syrus-chat-sidecar=connected")
      text = Nokogiri::HTML.fragment(html).text.squish

      expect(text).to include("Connected")
      expect(text).to include("MCP connected: syrus-chat-sidecar")
    end

    it "surfaces MCP server problems" do
      html = helper.render_chat_system_message("[mcp_servers] syrus-chat-sidecar=failed")
      text = Nokogiri::HTML.fragment(html).text.squish

      expect(text).to include("MCP")
      expect(text).to include("MCP issue: syrus-chat-sidecar failed")
    end

    it "keeps plain system notes readable" do
      html = helper.render_chat_system_message("Cancelled by operator.")
      text = Nokogiri::HTML.fragment(html).text.squish

      expect(text).to include("System")
      expect(text).to include("Cancelled by operator.")
    end
  end
end
