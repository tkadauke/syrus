# Side table for the large values that used to live inside steps.details.
# Only the keys in StepDetailValue::EXTERNALIZED_KEYS are stored here; the
# structural keys stay inline. The backfill moves existing grader output out of
# the inline column in batches and is safe to re-run.
class CreateStepDetailValues < ActiveRecord::Migration[8.1]
  EXTERNALIZED_KEYS = %w[ output ].freeze
  BATCH_SIZE = 200

  class MigrationStep < ActiveRecord::Base
    self.table_name = "steps"
  end

  class MigrationDetailValue < ActiveRecord::Base
    self.table_name = "step_detail_values"
  end

  def up
    unless table_exists?(:step_detail_values)
      create_table :step_detail_values do |t|
        # Syrus does not add database-level FKs; Step has_many ... dependent: :destroy.
        t.references :step, null: false, index: false
        t.string :key, null: false
        t.text :value, limit: 16.megabytes - 1, null: false
        t.timestamps
      end
    end
    unless index_exists?(:step_detail_values, [ :step_id, :key ], unique: true)
      add_index :step_detail_values, [ :step_id, :key ], unique: true
    end

    backfill
  end

  def down
    return unless table_exists?(:step_detail_values)

    MigrationStep.reset_column_information
    MigrationDetailValue.reset_column_information
    MigrationDetailValue.find_each do |entry|
      step = MigrationStep.find_by(id: entry.step_id)
      next unless step

      step.update_columns(details: parse(step.details).merge(entry.key => JSON.parse(entry.value)))
    end
    drop_table :step_detail_values
  end

  private

  def backfill
    MigrationStep.reset_column_information
    MigrationDetailValue.reset_column_information

    # Candidate rows are found by key presence so a re-run skips finished rows
    # without loading every Step. Rows are walked in id batches.
    scope = MigrationStep.where(
      EXTERNALIZED_KEYS.map { "JSON_EXTRACT(details, '$.#{_1}') IS NOT NULL" }.join(" OR ")
    )
    scope.in_batches(of: BATCH_SIZE) do |batch|
      batch.pluck(:id, :details).each do |id, raw|
        details = parse(raw)
        external = details.slice(*EXTERNALIZED_KEYS).compact
        next if external.empty?

        now = Time.current
        MigrationStep.transaction do
          external.each do |key, value|
            entry = MigrationDetailValue.find_or_initialize_by(step_id: id, key: key)
            entry.update!(value: JSON.generate(value), created_at: entry.created_at || now, updated_at: now)
          end
          MigrationStep.where(id: id).update_all(details: details.except(*EXTERNALIZED_KEYS))
        end
      end
    end
  end

  def parse(value)
    value.is_a?(String) ? JSON.parse(value) : value.to_h
  end
end
