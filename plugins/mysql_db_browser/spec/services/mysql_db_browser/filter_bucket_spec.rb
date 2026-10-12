require "rails_helper"

RSpec.describe MysqlDbBrowser::FilterBucket do
  def column(data_type:, column_type: data_type)
    { name: "value", data_type: data_type, column_type: column_type }
  end

  it "selects boolean before numeric for MySQL tinyint(1) columns" do
    expect(described_class.for_column(column(data_type: "tinyint", column_type: "tinyint(1)")))
      .to eq(MysqlDbBrowser::FilterBucket::BooleanBucket)
  end

  it "falls back to string behavior for unclassified MySQL column types" do
    expect(described_class.for_column(column(data_type: "json")))
      .to eq(MysqlDbBrowser::FilterBucket::StringBucket)
  end

  it "looks up buckets by their persisted schema names" do
    expect(described_class.for_name("date"))
      .to eq(MysqlDbBrowser::FilterBucket::DateBucket)
  end

  it "rejects filter schemas that name an unknown bucket" do
    expect { described_class.for_name("spatial") }
      .to raise_error(MysqlDbBrowser::FilterBucket::UnknownBucket, "unknown bucket spatial")
  end
end
