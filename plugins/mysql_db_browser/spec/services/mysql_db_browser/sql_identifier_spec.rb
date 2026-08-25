require "rails_helper"

RSpec.describe MysqlDbBrowser::SqlIdentifier do
  it "backtick-quotes a plain identifier" do
    expect(described_class.quote("status")).to eq("`status`")
  end

  it "doubles an embedded backtick so it cannot break out of identifier position" do
    expect(described_class.quote("weird`name")).to eq("`weird``name`")
  end

  it "quotes each segment of a dotted table.column reference independently" do
    expect(described_class.quote("orders.status")).to eq("`orders`.`status`")
  end

  it "doubles backticks in every dotted segment" do
    expect(described_class.quote("a`b.c`d")).to eq("`a``b`.`c``d`")
  end
end
