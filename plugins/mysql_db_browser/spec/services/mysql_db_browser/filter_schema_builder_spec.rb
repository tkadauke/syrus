require "rails_helper"

RSpec.describe MysqlDbBrowser::FilterSchemaBuilder do
  def column(name:, data_type:, column_type: data_type)
    { name: name, data_type: data_type, column_type: column_type }
  end

  it "maps varchar/text-like columns to the string bucket with contains/starts_with-style operators" do
    fields = described_class.build([ column(name: "email", data_type: "varchar", column_type: "varchar(255)") ])

    expect(fields.first).to include(field: "email", bucket: "string")
    expect(fields.first[:operators]).to include("contains", "equals", "is_set", "is_unset")
  end

  it "maps numeric columns to the number bucket" do
    fields = described_class.build([ column(name: "amount_cents", data_type: "int", column_type: "int(11)") ])

    expect(fields.first).to include(field: "amount_cents", bucket: "number")
    expect(fields.first[:operators]).to include("greater_than", "less_than", "between")
  end

  it "maps tinyint(1) to the boolean bucket instead of number" do
    fields = described_class.build([ column(name: "active", data_type: "tinyint", column_type: "tinyint(1)") ])

    expect(fields.first).to include(field: "active", bucket: "boolean")
    expect(fields.first[:operators]).to eq(%w[is_true is_false])
  end

  it "maps regular tinyint (not tinyint(1)) to the number bucket" do
    fields = described_class.build([ column(name: "retry_count", data_type: "tinyint", column_type: "tinyint(4)") ])

    expect(fields.first[:bucket]).to eq("number")
  end

  it "maps date/datetime/timestamp columns to the date bucket" do
    fields = described_class.build([
      column(name: "created_at", data_type: "datetime"),
      column(name: "due_on", data_type: "date"),
      column(name: "synced_at", data_type: "timestamp")
    ])

    expect(fields.map { |f| f[:bucket] }).to all(eq("date"))
  end

  it "maps enum columns to the enum bucket and parses the allowed values from COLUMN_TYPE" do
    fields = described_class.build([ column(name: "state", data_type: "enum", column_type: "enum('pending','active','done')") ])

    expect(fields.first).to include(field: "state", bucket: "enum")
    expect(fields.first[:values]).to eq(%w[pending active done])
    expect(fields.first[:operators]).to eq(%w[is is_not is_one_of is_none_of])
  end

  it "humanizes the label from the column name" do
    fields = described_class.build([ column(name: "default_database", data_type: "varchar") ])

    expect(fields.first[:label]).to eq("Default database")
  end

  it "qualifies the field and label with a table_prefix, for join-aware filter schemas" do
    fields = described_class.build([ column(name: "email", data_type: "varchar", column_type: "varchar(255)") ], table_prefix: "customers")

    expect(fields.first[:field]).to eq("customers.email")
    expect(fields.first[:label]).to eq("Customers: Email")
  end
end
