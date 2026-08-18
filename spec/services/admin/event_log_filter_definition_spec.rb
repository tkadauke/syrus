require "rails_helper"

RSpec.describe Admin::EventLogFilterDefinition do
  describe "browser error filters" do
    let(:user) { Factories.user }
    let(:definition) { Admin::EventLogFilterDefinitions.browser_errors }

    before do
      BrowserErrorEvent.create!(
        user: user,
        occurred_at: 10.minutes.ago,
        app_revision: SyrusVersion.current,
        fingerprint: "alpha",
        name: "TypeError",
        message: "undefined is not an object",
        path: "/jobs/3188",
        stack: "stack"
      )
      BrowserErrorEvent.create!(
        user: user,
        occurred_at: 10.minutes.ago,
        app_revision: SyrusVersion.current,
        fingerprint: "beta",
        name: "ReferenceError",
        message: "missing variable",
        path: "/admin/performance",
        stack: "stack"
      )
      BrowserErrorEvent.create!(
        user: user,
        occurred_at: 2.days.ago,
        app_revision: SyrusVersion.current,
        fingerprint: "old",
        name: "TypeError",
        message: "old error",
        path: "/jobs/3188",
        stack: "stack"
      )
    end

    it "builds schema from field metadata" do
      query = definition.schema.find { |field| field.fetch("field") == "query" }
      expect(query).to include(
        "label" => "Search",
        "bucket" => "text",
        "operators" => %w[contains does_not_contain]
      )
    end

    it "applies default filters and legacy flat params" do
      rows = definition.apply(BrowserErrorEvent.all, { path: "/jobs/3188" }).pluck(:fingerprint)

      expect(rows).to eq([ "alpha" ])
    end

    it "applies canonical q filters with richer operators" do
      q = Filters::QueryParam.encode(
        "and" => [
          { "field" => "query", "op" => "contains", "value" => "variable" },
          { "field" => "path", "op" => "does_not_contain", "value" => "jobs" }
        ]
      )

      rows = definition.apply(BrowserErrorEvent.all, { q: q }).pluck(:fingerprint)

      expect(rows).to eq([ "beta" ])
    end

    it "supports OR and NOT groups without table-specific code" do
      q = Filters::QueryParam.encode(
        "and" => [
          {
            "or" => [
              { "field" => "fingerprint", "op" => "is", "value" => "alpha" },
              { "field" => "fingerprint", "op" => "is", "value" => "beta" }
            ]
          },
          { "not" => { "field" => "path", "op" => "contains", "value" => "performance" } }
        ]
      )

      rows = definition.apply(BrowserErrorEvent.all, { q: q }).pluck(:fingerprint)

      expect(rows).to eq([ "alpha" ])
    end
  end
end
