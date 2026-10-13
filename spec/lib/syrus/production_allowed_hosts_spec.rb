# frozen_string_literal: true

require "rails_helper"

RSpec.describe Syrus::ProductionAllowedHosts do
  describe ".resolve" do
    it "uses the canonical app host when the extra hosts env is missing" do
      expect(described_class.resolve(app_host: "syrus.example.test", raw_allowed_hosts: nil))
        .to eq([ "syrus.example.test" ])
    end

    it "keeps the canonical app host when the extra hosts env is blank" do
      expect(described_class.resolve(app_host: "syrus.example.test", raw_allowed_hosts: " \t "))
        .to eq([ "syrus.example.test" ])
    end

    it "adds configured extra hosts without replacing the canonical app host" do
      expect(
        described_class.resolve(
          app_host: "syrus.example.test",
          raw_allowed_hosts: "extra.example.test, syrus-alt.example.test"
        )
      ).to eq([
        "syrus.example.test",
        "extra.example.test",
        "syrus-alt.example.test"
      ])
    end

    it "strips blanks and deduplicates the canonical app host" do
      expect(
        described_class.resolve(
          app_host: "syrus.example.test",
          raw_allowed_hosts: " , syrus.example.test, extra.example.test, extra.example.test"
        )
      ).to eq([
        "syrus.example.test",
        "extra.example.test"
      ])
    end
  end

  describe ".blank_env?" do
    it "is true only when SYRUS_ALLOWED_HOSTS is explicitly blank" do
      expect(described_class.blank_env?({})).to be(false)
      expect(described_class.blank_env?({ "SYRUS_ALLOWED_HOSTS" => "extra.example.test" })).to be(false)
      expect(described_class.blank_env?({ "SYRUS_ALLOWED_HOSTS" => " \n " })).to be(true)
    end
  end
end
