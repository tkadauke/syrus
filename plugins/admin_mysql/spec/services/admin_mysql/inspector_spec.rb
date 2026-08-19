require "rails_helper"

RSpec.describe AdminMysql::Inspector do
  it "reports unavailable when the Rails adapter is not mysql2" do
    expect(described_class.mysql?).to be(false)

    expect {
      described_class.new.snapshot
    }.to raise_error(described_class::Unavailable, /mysql2 adapter/)
  end
end
