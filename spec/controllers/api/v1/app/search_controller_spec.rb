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
      expect(described_class::SEARCH_ROWS_DISPATCH.keys).to match_array(described_class::BUILT_IN_TYPES)
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
      expect(described_class::RESULT_JSON_DISPATCH.keys).to match_array(described_class::BUILT_IN_TYPES)
    end
  end

  describe ".types" do
    it "includes the built-in types" do
      # Core's own types only; plugin-contributed ones are the next example's
      # subject, and naming one here makes its plugin undeletable.
      expect(described_class.types).to include("job", "epic", "chat")
    end

    it "appends a plugin-contributed type after the built-ins" do
      provider = Class.new do
        include Syrus::Plugin::SearchSource

        def self.search_type = "widget"
        def self.filter_subject = :job
        def self.row_id_key = :widget_id
        def self.search_rows(query:, user:, limit:) = []
        def self.result_json(row:, user:) = { id: 1 }
      end
      Syrus::PluginRegistry.register(name: "search_plugin", version: "1.0.0", provides: { search_source: provider })

      expect(described_class.types.last).to eq("widget")
      expect(described_class.filter_subjects["widget"]).to eq(:job)
    end

    it "drops a plugin type when the plugin is disabled" do
      provider = Class.new do
        include Syrus::Plugin::SearchSource

        def self.search_type = "widget"
        def self.filter_subject = :job
        def self.row_id_key = :widget_id
        def self.search_rows(query:, user:, limit:) = []
        def self.result_json(row:, user:) = { id: 1 }
      end
      Syrus::PluginRegistry.register(name: "search_plugin", version: "1.0.0", provides: { search_source: provider })
      PluginRecord.find_or_create_by!(name: "search_plugin").update!(enabled: false, disableable: true)

      expect(described_class.types).not_to include("widget")
    end
  end
end
