class ExtendProviderRoutingRulesForOrderedScopedRules < ActiveRecord::Migration[8.1]
  class MigrationProviderRoutingRule < ActiveRecord::Base
    self.table_name = "provider_routing_rules"
  end

  def up
    add_column :provider_routing_rules, :user_id, :integer unless column_exists?(:provider_routing_rules, :user_id)
    add_column :provider_routing_rules, :repository_id, :integer unless column_exists?(:provider_routing_rules, :repository_id)
    add_column :provider_routing_rules, :job_id, :integer unless column_exists?(:provider_routing_rules, :job_id)
    add_column :provider_routing_rules, :position, :integer unless column_exists?(:provider_routing_rules, :position)
    add_column :provider_routing_rules, :trigger, :json unless column_exists?(:provider_routing_rules, :trigger)
    add_column :provider_routing_rules, :conditions, :json unless column_exists?(:provider_routing_rules, :conditions)
    add_column :provider_routing_rules, :action, :json unless column_exists?(:provider_routing_rules, :action)

    backfill_existing_rules

    change_column_null :provider_routing_rules, :user_id, false
    change_column_null :provider_routing_rules, :position, false
    change_column_null :provider_routing_rules, :trigger, false
    change_column_null :provider_routing_rules, :conditions, false
    change_column_null :provider_routing_rules, :action, false

    if index_exists?(:provider_routing_rules, [ :scope_type, :scope_id, :task_key ], name: "idx_provider_routing_rules_scope_task_key_unique")
      remove_index :provider_routing_rules, name: "idx_provider_routing_rules_scope_task_key_unique"
    end

    add_index :provider_routing_rules, [ :scope_type, :scope_id, :position ],
              unique: true,
              name: "idx_provider_routing_rules_scope_position_unique" unless index_exists?(:provider_routing_rules, [ :scope_type, :scope_id, :position ], name: "idx_provider_routing_rules_scope_position_unique")
    add_index :provider_routing_rules, :user_id unless index_exists?(:provider_routing_rules, :user_id)
    add_index :provider_routing_rules, :repository_id unless index_exists?(:provider_routing_rules, :repository_id)
    add_index :provider_routing_rules, :job_id unless index_exists?(:provider_routing_rules, :job_id)
  end

  def down
    remove_index :provider_routing_rules, name: "idx_provider_routing_rules_scope_position_unique" if index_exists?(:provider_routing_rules, name: "idx_provider_routing_rules_scope_position_unique")
    remove_index :provider_routing_rules, :user_id if index_exists?(:provider_routing_rules, :user_id)
    remove_index :provider_routing_rules, :repository_id if index_exists?(:provider_routing_rules, :repository_id)
    remove_index :provider_routing_rules, :job_id if index_exists?(:provider_routing_rules, :job_id)

    add_index :provider_routing_rules, [ :scope_type, :scope_id, :task_key ],
              unique: true,
              name: "idx_provider_routing_rules_scope_task_key_unique" unless index_exists?(:provider_routing_rules, [ :scope_type, :scope_id, :task_key ], name: "idx_provider_routing_rules_scope_task_key_unique")

    remove_column :provider_routing_rules, :action if column_exists?(:provider_routing_rules, :action)
    remove_column :provider_routing_rules, :conditions if column_exists?(:provider_routing_rules, :conditions)
    remove_column :provider_routing_rules, :trigger if column_exists?(:provider_routing_rules, :trigger)
    remove_column :provider_routing_rules, :position if column_exists?(:provider_routing_rules, :position)
    remove_column :provider_routing_rules, :job_id if column_exists?(:provider_routing_rules, :job_id)
    remove_column :provider_routing_rules, :repository_id if column_exists?(:provider_routing_rules, :repository_id)
    remove_column :provider_routing_rules, :user_id if column_exists?(:provider_routing_rules, :user_id)
  end

  private

  def backfill_existing_rules
    MigrationProviderRoutingRule.reset_column_information

    MigrationProviderRoutingRule.order(:scope_type, :scope_id, :task_key, :id).group_by { |rule| [ rule.scope_type, rule.scope_id ] }.each_value do |rules|
      rules.each_with_index do |rule, index|
        attrs = {
          position: rule.position || index + 1,
          trigger: rule.trigger.presence || legacy_trigger_for(rule.task_key),
          conditions: rule.conditions.presence || {},
          action: rule.action.presence || { strategy: "fallback_order", candidates: Array(rule.candidates) }
        }.merge(owner_attrs_for(rule))

        rule.update_columns(attrs.compact.merge(updated_at: Time.current))
      end
    end
  end

  def owner_attrs_for(rule)
    case rule.scope_type
    when "user"
      { user_id: rule.scope_id }
    when "repository"
      repository = connection.select_one(sanitize_sql([ "SELECT user_id FROM repositories WHERE id = ?", rule.scope_id ]))
      { user_id: repository&.fetch("user_id"), repository_id: rule.scope_id }
    when "job"
      job = connection.select_one(sanitize_sql([ "SELECT COALESCE(owner_user_id, user_id) AS user_id, repository_id FROM jobs WHERE id = ?", rule.scope_id ]))
      { user_id: job&.fetch("user_id"), repository_id: job&.fetch("repository_id"), job_id: rule.scope_id }
    else
      {}
    end
  end

  def legacy_trigger_for(task_key)
    task_key == "default" ? { type: "default" } : { type: "legacy_task", task_key: task_key }
  end

  def sanitize_sql(array)
    ActiveRecord::Base.sanitize_sql_array(array)
  end
end
