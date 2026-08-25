class BackfillActiveWorkUnits < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  BATCH_SIZE = 100

  def up
    return unless table_exists?(:work_units)
    return unless table_exists?(:work_intents)
    return unless table_exists?(:workflows)

    say_with_time "Backfilling active WorkUnit rows for queued/running workflows" do
      loop do
        results = WorkUnits::Backfill.active!(limit: BATCH_SIZE)
        break if results.empty?
        break if results.none?(&:created?)
      end
    end
  end

  def down
    # Data migration only. WorkUnit rows may have advanced after deploy.
  end
end
