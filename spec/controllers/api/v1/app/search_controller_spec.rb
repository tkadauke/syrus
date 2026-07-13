require "rails_helper"

RSpec.describe Api::V1::App::SearchController do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }

  before { allow(Current).to receive(:user).and_return(user) }

  describe "SEARCH_ROWS_DISPATCH" do
    it "maps each supported type to a private method" do
      controller_instance = described_class.new
      described_class::SEARCH_ROWS_DISPATCH.each do |type, method_name|
        expect(controller_instance.respond_to?(method_name, true)).to be(true),
          "expected #{described_class}##{method_name} to exist for type '#{type}'"
      end
    end

    it "covers all declared TYPES" do
      expect(described_class::SEARCH_ROWS_DISPATCH.keys).to match_array(described_class::TYPES)
    end
  end

  describe "RESULT_JSON_DISPATCH" do
    it "maps each supported type to a private method" do
      controller_instance = described_class.new
      described_class::RESULT_JSON_DISPATCH.each do |type, method_name|
        expect(controller_instance.respond_to?(method_name, true)).to be(true),
          "expected #{described_class}##{method_name} to exist for type '#{type}'"
      end
    end

    it "covers all declared TYPES" do
      expect(described_class::RESULT_JSON_DISPATCH.keys).to match_array(described_class::TYPES)
    end
  end
end
