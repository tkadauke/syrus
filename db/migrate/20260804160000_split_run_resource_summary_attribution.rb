class SplitRunResourceSummaryAttribution < ActiveRecord::Migration[8.1]
  RENAMES = {
    sample_confidence: :host_sample_confidence,
    avg_cpu_used_percent: :host_usage_avg_cpu_used_percent,
    max_cpu_used_percent: :host_usage_max_cpu_used_percent,
    avg_cpu_pressure: :host_pressure_avg_cpu_some_percent,
    max_cpu_pressure: :host_pressure_max_cpu_some_percent,
    avg_memory_used_percent: :host_usage_avg_memory_used_percent,
    max_memory_used_percent: :host_usage_max_memory_used_percent,
    avg_io_pressure: :host_pressure_avg_io_some_percent,
    max_io_pressure: :host_pressure_max_io_some_percent,
    max_data_root_used_percent: :host_usage_max_data_root_used_percent,
    resource_pressure_level: :host_pressure_level,
    resource_pressure_reasons: :host_pressure_reasons
  }.freeze

  def up
    RENAMES.each do |old_name, new_name|
      rename_column :run_resource_summaries, old_name, new_name if column_exists?(:run_resource_summaries, old_name)
    end
    add_column :run_resource_summaries, :process_attribution_method, :string, null: false, limit: 64, default: "unknown"
    add_column :run_resource_summaries, :process_attribution_version, :integer, null: false, default: 1
    add_column :run_resource_summaries, :process_attribution_confidence, :string, null: false, limit: 32, default: "unknown"
    add_column :run_resource_summaries, :process_sample_count, :integer, null: false, default: 0
    add_column :run_resource_summaries, :process_cpu_time_seconds, :float
    add_column :run_resource_summaries, :process_wall_time_seconds, :float
    add_column :run_resource_summaries, :process_max_rss_bytes, :bigint
    add_column :run_resource_summaries, :process_read_io_bytes, :bigint
    add_column :run_resource_summaries, :process_write_io_bytes, :bigint
    add_column :run_resource_summaries, :process_descendant_process_count, :integer, null: false, default: 0
    add_column :run_resource_summaries, :process_exit_statuses, :json
    add_column :run_resource_summaries, :process_attribution_unavailable_reason, :string, limit: 255
    add_column :run_resource_summaries, :process_resource_fallback, :boolean, null: false, default: false

    add_column :spawned_processes, :resource_attribution, :json unless column_exists?(:spawned_processes, :resource_attribution)
    add_column :command_spans, :resource_attribution, :json unless column_exists?(:command_spans, :resource_attribution)
  end

  def down
    remove_column :command_spans, :resource_attribution if column_exists?(:command_spans, :resource_attribution)
    remove_column :spawned_processes, :resource_attribution if column_exists?(:spawned_processes, :resource_attribution)

    %i[
      process_attribution_method
      process_attribution_version
      process_attribution_confidence
      process_sample_count
      process_cpu_time_seconds
      process_wall_time_seconds
      process_max_rss_bytes
      process_read_io_bytes
      process_write_io_bytes
      process_descendant_process_count
      process_exit_statuses
      process_attribution_unavailable_reason
      process_resource_fallback
    ].each do |column_name|
      remove_column :run_resource_summaries, column_name if column_exists?(:run_resource_summaries, column_name)
    end

    RENAMES.each do |old_name, new_name|
      rename_column :run_resource_summaries, new_name, old_name if column_exists?(:run_resource_summaries, new_name)
    end
  end
end
