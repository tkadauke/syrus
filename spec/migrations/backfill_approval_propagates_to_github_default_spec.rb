require "rails_helper"
require Rails.root.join("db/migrate/20260517225759_backfill_approval_propagates_to_github_default")

RSpec.describe BackfillApprovalPropagatesToGithubDefault do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  after do
    migration.up
  end

  it "backfills null repository values, sets a database default, and is idempotent" do
    user = Factories.user
    migration.down
    repository = Factories.repository(user: user, owner: "acme", name: "null-default")
    repository.update_column(:approval_propagates_to_github, nil)

    migration.up
    migration.up

    expect(repository.reload.approval_propagates_to_github).to be(true)

    raw_name = "raw-default-#{SecureRandom.hex(4)}"
    quoted_now = connection.quote(Time.current)
    connection.execute(<<~SQL.squish)
      INSERT INTO repositories (user_id, owner, name, created_at, updated_at)
      VALUES (#{user.id}, 'acme', #{connection.quote(raw_name)}, #{quoted_now}, #{quoted_now})
    SQL

    expect(Repository.find_by!(name: raw_name).approval_propagates_to_github).to be(true)
  end
end
