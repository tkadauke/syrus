require "rails_helper"

RSpec.describe GithubAppInstallationDiagnostic do
  let(:admin) { Factories.user(admin: true) }

  before do
    AppSetting.current.update!(
      github_app_id: 42,
      github_app_slug: "operator-syrus",
      github_app_private_key_pem: OpenSSL::PKey::RSA.generate(2048).to_pem,
      github_app_registered_at: 1.day.ago
    )
  end

  it "reports an active owner installation that is not linked to the repository" do
    repo = Factories.repository(user: admin, owner: "acme", name: "widgets", github_owner_id: 10, github_repository_id: 20)
    installation = Factories.installation(user: admin, account_login: "acme")

    payload = described_class.new(slug: repo.slug).show
    row = payload.fetch(:repositories).first

    expect(payload.fetch(:global)).to include(jwt_usable: true, registered: true)
    expect(payload.fetch(:installations).first).to include(id: installation.id, active: true)
    expect(row).to include(
      slug: "acme/widgets",
      app_credential_active: false,
      app_credential_inactive_reason: "repository_installation_link_missing",
      recommended_next_action: "relink_repository_to_existing_active_installation"
    )
  end

  it "distinguishes a removed installation row from missing GitHub repository ids" do
    removed = Factories.installation(user: admin, account_login: "globex", removed_at: 1.hour.ago)
    removed_repo = Factories.repository(user: admin, owner: "globex")
    removed_repo.update_columns(installation_id: removed.id)
    idless_repo = Factories.repository(user: admin, owner: "initech", github_owner_id: 33, github_repository_id: nil)

    removed_row = described_class.new(slug: removed_repo.slug).show.fetch(:repositories).first
    idless_row = described_class.new(slug: idless_repo.slug).show.fetch(:repositories).first

    expect(removed_row.fetch(:app_credential_inactive_reason)).to eq("linked_installation_removed")
    expect(removed_row.fetch(:recommended_next_action)).to eq("reinstall_app_for_owner_or_repo")
    expect(idless_row.fetch(:install_url_missing_reason)).to eq("github_repository_id_missing")
    expect(idless_row.fetch(:app_credential_inactive_reason)).to eq("github_repository_ids_missing")
    expect(idless_row.fetch(:recommended_next_action)).to eq("reselect_repository_to_capture_github_ids")
  end

  it "includes membership-level installation state that can affect the effective client" do
    repo_installation = Factories.installation(user: admin, account_login: "acme")
    member_installation = Factories.installation(user: admin, account_login: "other")
    member = Factories.user(email_address: "member@example.com")
    repo = Factories.repository(user: admin, owner: "acme", installation: repo_installation)
    repo.repository_memberships.create!(user: member, role: "collaborator", installation: member_installation)

    row = described_class.new(slug: repo.slug).show.fetch(:repositories).first
    membership = row.fetch(:membership_installations).find { |item| item.fetch(:user_id) == member.id }

    expect(membership).to include(
      user_email: "member@example.com",
      installation_id: member_installation.id,
      effective_client_installation_id: member_installation.id
    )
  end

  it "reports invalid JWT signing state" do
    AppSetting.current.update!(github_app_private_key_pem: "not a key")

    payload = described_class.new.show

    expect(payload.fetch(:global)).to include(
      jwt_usable: false,
      jwt_error_class: "OpenSSL::PKey::RSAError"
    )
  end
end
