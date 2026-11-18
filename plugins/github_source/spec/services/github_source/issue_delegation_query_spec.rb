require "rails_helper"

RSpec.describe GithubSource::IssueDelegationQuery do
  describe ".for" do
    it "builds a MySQL JSON path predicate" do
      connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, adapter_name: "Mysql2")

      expect(described_class.for(connection).condition("syrus")).to eq([
        "JSON_CONTAINS(labels, JSON_OBJECT('name', ?))",
        "syrus"
      ])
    end

    it "builds a SQLite JSON path predicate" do
      connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, adapter_name: "SQLite")

      expect(described_class.for(connection).condition("syrus")).to eq([
        "EXISTS (SELECT 1 FROM json_each(labels) WHERE json_extract(json_each.value, '$.name') = ?)",
        "syrus"
      ])
    end
  end
end
