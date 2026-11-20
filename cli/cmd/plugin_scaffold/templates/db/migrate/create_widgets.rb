class Create{{MODULE_NAME}}Widgets < ActiveRecord::Migration[8.1]
  def change
    create_table :{{PLUGIN_NAME}}_widgets do |table|
      table.string :name, null: false
      table.timestamps
    end
  end
end
