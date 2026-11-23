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
      base.has_one :main_branch_health_state,
        class_name: "MainBranchHealth::RepositoryState",
        foreign_key: :repository_id,
        inverse_of: :repository
      base.send(:default_scope, -> { includes(:main_branch_health_state) })
      base.enum :ci_health, base::CI_HEALTH_STATES.index_with(&:itself), prefix: true, validate: true
      base.enum :grader_health, base::GRADER_HEALTH_STATES.index_with(&:itself), prefix: true, validate: true
      install_attribute_readers(base)
      install_enum_predicates(base, :ci_health, base::CI_HEALTH_STATES)
      install_enum_predicates(base, :grader_health, base::GRADER_HEALTH_STATES)
      base.scope :with_main_branch_health_enabled, -> {
        where(id: MainBranchHealth::RepositoryState.where(main_branch_health_enabled: true).select(:repository_id))
      }
      base.scope :with_broken_main_branch, -> {
        states = MainBranchHealth::RepositoryState
          .where(main_branch_health_enabled: true)
          .where("ci_health = :broken OR grader_health = :broken", broken: "broken")
        where(id: states.select(:repository_id))
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
      base.after_save :persist_main_branch_health_state
      base.after_destroy :destroy_main_branch_health_state
    end

    def self.install_attribute_readers(base)
      FIELDS.each_key do |name|
        base.define_method(name) do
          load_main_branch_health_state
          super()
        end
        base.define_method("#{name}?") do
          load_main_branch_health_state
          super()
        end
        base.define_method("#{name}=") do |value|
          load_main_branch_health_state if persisted?
          super(value)
        end
      end
    end

    def self.install_enum_predicates(base, name, values)
      values.each do |value|
        base.define_method("#{name}_#{value}?") do
          load_main_branch_health_state
          super()
        end
      end
    end

    def update_columns(attributes)
      plugin, core = attributes.stringify_keys.partition { |key, _| FIELDS.key?(key.to_sym) }.map(&:to_h)
      write_main_branch_health_columns(plugin) if plugin.any?
      core.any? ? super(core) : true
    end

    def reload(...)
      @main_branch_health_state_loaded = false
      super
    end

    private

    def load_main_branch_health_state
      return if @main_branch_health_state_loaded

      @main_branch_health_state_loaded = true
      return unless persisted?

      state = main_branch_health_state
      values = FIELDS.to_h { |name, (_, default)| [ name, state ? state.public_send(name) : default ] }
      values.each { |name, value| self[name] = value }
      clear_attribute_changes(FIELDS.keys)
    end

    def persist_main_branch_health_state
      names = previously_new_record? ? FIELDS.keys : FIELDS.keys.select { |name| saved_change_to_attribute?(name) }
      return if names.empty?

      state = MainBranchHealth::RepositoryState.find_or_initialize_by(repository_id: id)
      state.assign_attributes(names.index_with { |name| self[name] })
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
