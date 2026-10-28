require "rails_helper"
require Rails.root.join("db/migrate/20261028100206_restore_land_on_inherited_check_failure_for_rolling_deploys")

RSpec.describe RestoreLandOnInheritedCheckFailureForRollingDeploys, :ci_only do
  let(:migration) { described_class.new }

  after do
    migration.migrate(:up) unless ActiveRecord::Base.connection.column_exists?(:repositories, described_class::LEGACY)
    Repository.reset_column_information
  end

  it "restores equivalent legacy values for repositories created before the repair" do
    migration.migrate(:down)
    Repository.reset_column_information

    repositories = %w[all own_only none].index_with do |gate|
      Repository.create!(user: Factories.user, owner: "acme", name: "#{gate}-checks", pr_check_gate: gate)
    end

    migration.migrate(:up)
    Repository.reset_column_information

    expect(repositories.transform_values { |repository| repository.reload[:land_on_inherited_check_failure] }).to eq(
      "all" => false,
      "own_only" => true,
      "none" => true
    )
  end
end
