require "rails_helper"

RSpec.describe McpToolUsage do
  describe ".in_window" do
    it "uses an index-friendly created_at range predicate" do
      sql = described_class.in_window(2.hours.ago, Time.current).to_sql

      expect(sql).to include(%("mcp_tool_usages"."created_at"))
      expect(sql).not_to include("COALESCE")
    end
  end
end
