require "rails_helper"

RSpec.describe Api::V1::Admin::BaseController do
  describe "#truthy?" do
    subject(:controller) { described_class.new }

    it "accepts the canonical case-insensitive truthy query values" do
      expect([ "true", "TRUE", "1", 1, "yes", "YES" ]).to all(satisfy { |value| controller.send(:truthy?, value) })
    end

    it "rejects other and missing query values" do
      expect([ "false", "0", "no", "on", "", nil ]).to all(satisfy { |value| !controller.send(:truthy?, value) })
    end
  end
end
