require "rails_helper"

RSpec.describe TurboHelper, type: :helper do
  describe "#safe_turbo_frame" do
    it "defaults frame navigation to the top window" do
      html = helper.safe_turbo_frame("dashboard_content") { "Dashboard" }
      frame = Nokogiri::HTML.fragment(html).at_css("turbo-frame")

      expect(frame["id"]).to eq("dashboard_content")
      expect(frame["target"]).to eq("_top")
    end

    it "allows callers to opt back into in-frame navigation" do
      html = helper.safe_turbo_frame("drawer_body", target: nil) { "Drawer" }
      frame = Nokogiri::HTML.fragment(html).at_css("turbo-frame")

      expect(frame["target"]).to be_nil
    end
  end
end
