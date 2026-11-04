require "rails_helper"
require Rails.root.join("db/migrate/20261104120818_migrate_coworker_grants_to_permission_rules")

RSpec.describe MigrateCoworkerGrantsToPermissionRules do
  subject(:migration) { described_class.new }

  it "reports translation diagnostics without aborting the migration" do
    result = Coworkers::LegacyGrantMigration::Result.new(
      migrated: 1, already_migrated: 0, already_canonical: 0,
      conflicts: [], parity_errors: [], errors: [ { grant_id: 7 } ]
    )
    allow(migration).to receive(:table_exists?).and_return(true)
    allow(migration).to receive(:say)
    allow(Coworkers::LegacyGrantMigration).to receive(:call).and_return(result)

    expect { migration.up }.not_to raise_error
    expect(migration).to have_received(:say).with(/\"errors\":\[\{\"grant_id\":7\}\]/)
  end

  it "revokes migrated rules on rollback and reports preserved legacy rows" do
    actor = instance_double(User)
    rule = instance_double(PermissionRule, created_by_user: actor)
    relation = instance_double(ActiveRecord::Relation)
    allow(migration).to receive(:table_exists?).and_return(true)
    allow(migration).to receive(:say)
    allow(PermissionRule).to receive(:where).and_return(relation)
    allow(relation).to receive(:find_each).and_yield(rule)
    allow(rule).to receive(:revoke!)

    migration.down

    expect(rule).to have_received(:revoke!).with(actor: actor)
    expect(migration).to have_received(:say).with(/revoked 1 migrated rules/)
  end
end
