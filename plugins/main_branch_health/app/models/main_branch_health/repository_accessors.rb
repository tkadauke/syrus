module MainBranchHealth
  module RepositoryAccessors
    FIELDS = {
      ci_health: [ :string, "unknown" ], grader_health: [ :string, "unknown" ],
      last_health_checked_sha: [ :string, nil ], landing_paused: [ :boolean, false ],
      main_branch_health_enabled: [ :boolean, false ], main_branch_repair_enabled: [ :boolean, false ],
      last_graded_sha: [ :string, nil ], last_ci_evaluated_sha: [ :string, nil ],
      main_branch_repair_auto_approve: [ :boolean, false ], main_health_poll_error_streak: [ :integer, 0 ],
      last_main_health_poll_error_at: [ :datetime, nil ], main_branch_repair_blocks_work: [ :boolean, false ]
    }.freeze

    def self.included(base)
      FIELDS.each { |name, (type, default)| base.attribute(name, type, default: default) }
      base.scope :with_main_branch_health_enabled, -> {
        where(id: MainBranchHealth::RepositoryState.where(main_branch_health_enabled: true).select(:repository_id))
      }
      base.scope :with_broken_main_branch_repair, -> {
        states = MainBranchHealth::RepositoryState
          .where(main_branch_health_enabled: true, main_branch_repair_enabled: true)
          .where("ci_health = :broken OR grader_health = :broken", broken: "broken")
        where(id: states.select(:repository_id))
      }
      base.scope :with_main_branch_repair_enabled, -> {
        states = MainBranchHealth::RepositoryState.where(main_branch_health_enabled: true, main_branch_repair_enabled: true)
        where(id: states.select(:repository_id))
      }
      base.after_find :load_main_branch_health_state
      base.after_save :persist_main_branch_health_state
      base.after_destroy :destroy_main_branch_health_state
    end

    def update_columns(attributes)
      plugin, core = attributes.stringify_keys.partition { |key, _| FIELDS.key?(key.to_sym) }.map(&:to_h)
      write_main_branch_health_columns(plugin) if plugin.any?
      core.any? ? super(core) : true
    end

    def reload(...)
      super.tap { load_main_branch_health_state }
    end

    private

    def load_main_branch_health_state
      state = MainBranchHealth::RepositoryState.find_by(repository_id: id)
      values = FIELDS.to_h { |name, (_, default)| [ name, state ? state.public_send(name) : default ] }
      assign_attributes(values)
      clear_attribute_changes(FIELDS.keys)
    end

    def persist_main_branch_health_state
      names = previously_new_record? ? FIELDS.keys : FIELDS.keys.select { |name| saved_change_to_attribute?(name) }
      return if names.empty?

      state = MainBranchHealth::RepositoryState.find_or_initialize_by(repository_id: id)
      state.assign_attributes(names.index_with { |name| public_send(name) })
      state.save!
      clear_attribute_changes(names)
    end

    def write_main_branch_health_columns(attributes)
      state = MainBranchHealth::RepositoryState.find_or_initialize_by(repository_id: id)
      state.assign_attributes(attributes)
      state.save!
      attributes.each { |key, value| public_send("#{key}=", value) }
      clear_attribute_changes(attributes.keys)
    end

    def destroy_main_branch_health_state
      MainBranchHealth::RepositoryState.where(repository_id: id).delete_all
    end
  end
end
