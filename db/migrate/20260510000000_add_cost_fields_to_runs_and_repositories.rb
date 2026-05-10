class AddCostFieldsToRunsAndRepositories < ActiveRecord::Migration[8.1]
  def change
    add_column :runs, :cost_usd, :decimal, precision: 12, scale: 6
    add_column :runs, :input_tokens, :integer
    add_column :runs, :output_tokens, :integer
    add_column :runs, :cache_creation_input_tokens, :integer
    add_column :runs, :cache_read_input_tokens, :integer

    add_column :repositories, :pr_cost_footer_enabled, :boolean, default: true, null: false
  end
end
