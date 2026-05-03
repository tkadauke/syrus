require "rails_helper"

RSpec.describe ApplicationHelper, type: :helper do
  def with_env(**vars)
    saved = vars.transform_values { |_| nil }
    saved.each_key { |k| saved[k] = ENV[k.to_s] }
    vars.each { |k, v| ENV[k.to_s] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k.to_s) : ENV[k.to_s] = v }
  end

  describe "#app_revision" do
    it "returns 'dev' when GIT_SHA isn't set" do
      with_env(GIT_SHA: nil) do
        expect(helper.app_revision).to eq("dev")
      end
    end

    it "returns the baked GIT_SHA when present" do
      with_env(GIT_SHA: "abc1234") do
        expect(helper.app_revision).to eq("abc1234")
      end
    end

    it "treats blank GIT_SHA as unset" do
      with_env(GIT_SHA: "") do
        expect(helper.app_revision).to eq("dev")
      end
    end
  end

  describe "#app_revision_url" do
    it "is nil for the dev revision" do
      with_env(GIT_SHA: nil) do
        expect(helper.app_revision_url).to be_nil
      end
    end

    it "links to the GitHub commit when GIT_SHA is set" do
      with_env(GIT_SHA: "abc1234") do
        expect(helper.app_revision_url).to eq("https://github.com/tkadauke/syrus/commit/abc1234")
      end
    end
  end

  describe "#relative_timestamp" do
    it "returns the fallback for nil" do
      expect(helper.relative_timestamp(nil)).to eq("—")
    end

    it "returns the custom fallback for nil" do
      expect(helper.relative_timestamp(nil, fallback: "N/A")).to eq("N/A")
    end

    it "renders a <time> element with the iso8601 datetime attribute" do
      time = 5.minutes.ago
      html = helper.relative_timestamp(time)
      node = Nokogiri::HTML.fragment(html).at("time")
      expect(node).to be_present
      expect(node["datetime"]).to eq(time.iso8601)
    end

    it "includes the absolute time in the title attribute" do
      time = Time.zone.local(2025, 3, 15, 14, 30)
      html = helper.relative_timestamp(time)
      node = Nokogiri::HTML.fragment(html).at("time")
      expect(node["title"]).to eq("Mar 15, 2025 at 2:30 PM")
    end

    it "attaches the relative-time Stimulus controller" do
      html = helper.relative_timestamp(5.minutes.ago)
      node = Nokogiri::HTML.fragment(html).at("time")
      expect(node["data-controller"]).to eq("relative-time")
    end

    it "renders a past timestamp as 'X ago'" do
      html = helper.relative_timestamp(5.minutes.ago)
      node = Nokogiri::HTML.fragment(html).at("time")
      expect(node.text).to match(/ago\z/)
    end

    it "renders a future timestamp as 'in X'" do
      html = helper.relative_timestamp(5.minutes.from_now)
      node = Nokogiri::HTML.fragment(html).at("time")
      expect(node.text).to match(/\Ain /)
    end
  end

end
