require "rails_helper"

RSpec.describe CredentialStore::AdminPages do
  it "advertises the credential management admin page" do
    expect(described_class.admin_pages).to contain_exactly(
      include(
        id: "credential_store.credentials",
        path: "/admin/credential_store",
        component: "credential_store/CredentialStoreAdmin"
      )
    )
  end
end
