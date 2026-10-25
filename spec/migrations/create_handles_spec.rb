require "rails_helper"
require Rails.root.join("db/migrate/20261025233430_create_handles")

RSpec.describe CreateHandles do
  it "backfills missing user handles and can be rerun" do
    user = Factories.user(email_address: "fallback.person@example.com", github_handle: "Existing.User")
    Handle.find_by!(owner: user).destroy!

    expect { described_class.new.migrate(:up) }.to change { Handle.where(owner: user).count }.from(0).to(1)
    expect { described_class.new.migrate(:up) }.not_to change(Handle, :count)
    expect(Handle.find_by!(owner: user).handle).to eq("existing-user")
    expect(Handle.find_by!(handle: "syrus")).to be_reserved
  end
end
