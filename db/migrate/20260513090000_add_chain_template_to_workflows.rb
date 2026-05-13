class AddChainTemplateToWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_column :workflows, :chain_template, :text
  end
end
