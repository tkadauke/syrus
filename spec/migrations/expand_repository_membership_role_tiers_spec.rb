require "rails_helper"
require Rails.root.join("db/migrate/20260823212331_expand_repository_membership_role_tiers")

RSpec.describe ExpandRepositoryMembershipRoleTiers, :ci_only do
  let(:conn) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  # Ensure the migration is always left applied so subsequent specs see a clean schema.
  after { migration.up }

  it "maps existing owner rows to admin and collaborator rows to read" do
    user = Factories.user
    repo = Factories.repository(user: user)
    other_user = Factories.user

    migration.down

    now = conn.quote(Time.current)
    conn.execute(<<~SQL)
      UPDATE repository_memberships SET role = 'owner' WHERE repository_id = #{repo.id} AND user_id = #{user.id}
    SQL
    conn.execute(<<~SQL)
      INSERT INTO repository_memberships (repository_id, user_id, role, created_at, updated_at)
      VALUES (#{repo.id}, #{other_user.id}, 'collaborator', #{now}, #{now})
    SQL

    migration.up

    expect(RepositoryMembership.find_by(repository_id: repo.id, user_id: user.id).role).to eq("admin")
    expect(RepositoryMembership.find_by(repository_id: repo.id, user_id: other_user.id).role).to eq("read")
  end

  it "changes the role column default from owner to read" do
    expect(conn.columns(:repository_memberships).find { |c| c.name == "role" }.default).to eq("read")

    migration.down

    expect(conn.columns(:repository_memberships).find { |c| c.name == "role" }.default).to eq("owner")
  end
end
