require "rails_helper"
require Rails.root.join("db/migrate/20260703051210_refactor_repositories_uniqueness_and_add_memberships")

RSpec.describe RefactorRepositoriesUniquenessAndAddMemberships do
  let(:conn) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  # Ensure the migration is always left applied so subsequent specs see a clean schema.
  after { migration.up }

  it "collapses duplicate [owner, name] repository rows before adding the unique index" do
    user1 = Factories.user
    user2 = Factories.user

    migration.down

    # Insert two repositories with the same [owner, name] but different user_ids.
    # This was valid under the old [user_id, owner, name] unique key and is the
    # real-world scenario that caused the UNIQUE constraint failure on upgrade.
    # We bypass model validations with raw SQL because the model-level uniqueness
    # check now reflects the new [owner, name] scope.
    now = conn.quote(Time.current)
    conn.execute(<<~SQL)
      INSERT INTO repositories (user_id, owner, name, trigger_label, polling_enabled, default_branch, created_at, updated_at)
      VALUES (#{user1.id}, 'acme', 'shared-repo', 'syrus', 1, 'main', #{now}, #{now}),
             (#{user2.id}, 'acme', 'shared-repo', 'syrus', 1, 'main', #{now}, #{now})
    SQL

    canonical_id, duplicate_id = conn.select_values(
      "SELECT id FROM repositories WHERE owner = 'acme' AND name = 'shared-repo' ORDER BY id ASC"
    )

    # Create a job pointing to the duplicate row to verify FK redirect.
    duplicate_repo = Repository.find(duplicate_id)
    job = Factories.job_record(user: user2, repository: duplicate_repo)

    migration.up

    # Only the canonical row should remain.
    expect(Repository.where(owner: "acme", name: "shared-repo").count).to eq(1)
    expect(Repository.where(id: duplicate_id)).not_to exist

    # FK references must be retargeted to the canonical row.
    expect(job.reload.repository_id).to eq(canonical_id)

    # Both users should have membership rows on the canonical repository.
    member_user_ids = RepositoryMembership.where(repository_id: canonical_id).pluck(:user_id)
    expect(member_user_ids).to contain_exactly(user1.id, user2.id)
  end
end
