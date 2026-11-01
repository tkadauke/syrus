require "rails_helper"

RSpec.describe SearchIndexVersion do
  before do
    described_class.ensure_table!
    SearchRecord.connection.execute("DELETE FROM #{described_class::TABLE_NAME}")
  end

  it "stores completed versions independently per entity" do
    described_class.write!("jobs", "1")
    described_class.write!("epics", "2")

    expect(described_class.current("jobs")).to eq("1")
    expect(described_class.current("epics")).to eq("2")
    expect(described_class.current("logs")).to be_nil
  end
end
