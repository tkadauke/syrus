class CreateSyrusCoverageHitMaps < ActiveRecord::Migration[8.1]
  def change
    return if table_exists?(:syrus_coverage_hit_maps)

    create_table :syrus_coverage_hit_maps do |t|
      t.references :workflow, null: false, index: { unique: true, name: "idx_syrus_coverage_hit_maps_workflow" }
      t.timestamps
    end
    add_index :syrus_coverage_hit_maps, :created_at, name: "idx_syrus_coverage_hit_maps_created"
  end
end
