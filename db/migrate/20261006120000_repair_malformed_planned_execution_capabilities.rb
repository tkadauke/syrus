class RepairMalformedPlannedExecutionCapabilities < ActiveRecord::Migration[8.1]
  DEFAULT_CAPABILITIES = { "os" => [ "linux" ] }.freeze
  MACOS_CAPABILITIES = { "os" => [ "macos" ] }.freeze
  TABLES = %i[jobs workflows chat_proposals].freeze

  class PlannedExecutionRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  def up
    TABLES.each { |table| repair_table(table) }
  end

  def down
    # Data repair is intentionally irreversible.
  end

  private

  def repair_table(table)
    return unless column_exists?(table, :planned_execution_capabilities)

    model = Class.new(PlannedExecutionRecord) do
      self.table_name = table.to_s
    end

    model.find_each do |record|
      normalized = normalized_capabilities(record.planned_execution_capabilities)
      next if record.planned_execution_capabilities == normalized

      record.update_columns(
        planned_execution_capabilities: normalized,
        planned_execution_source: record.planned_execution_source.presence || "defaulted"
      )
    end
  end

  def normalized_capabilities(value)
    return DEFAULT_CAPABILITIES unless value.is_a?(Hash)

    os_values = Array(value["os"] || value[:os]).map { |os| os.to_s.strip.downcase }
    return MACOS_CAPABILITIES if os_values.include?("macos")

    DEFAULT_CAPABILITIES
  end
end
