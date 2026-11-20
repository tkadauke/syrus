class CreateRelocatablePluginProbes < ActiveRecord::Migration[8.1]
  def change
    create_table :relocatable_plugin_probes do |table|
      table.string :value, null: false
    end
  end
end
