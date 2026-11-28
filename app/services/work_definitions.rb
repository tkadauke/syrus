module WorkDefinitions
  class Error < StandardError; end
  class UnknownKind < Error; end

  module_function

  def for(kind)
    kind = kind.to_s
    definition_class = registry.fetch(kind) do
      raise UnknownKind, "unknown work definition kind=#{kind.inspect}"
    end
    definition_class.new
  end

  # The definition for a row that already exists. A plugin that is disabled or
  # unhealthy withdraws its kinds from the registry, which is right for new
  # work, but its in-flight Workflows still have to be finished or cancelled,
  # and the cancel cascade asks their definition questions. So an existing row
  # resolves its own kind from any installed plugin, enabled and healthy or
  # not (the definition is metadata; nothing here starts work), and otherwise
  # gets the neutral Unavailable definition (NY14,
  # formal/SyrusModel/ExistingKindDefinition.lean).
  def for_existing(kind)
    self.for(kind)
  rescue UnknownKind
    (installed_definition_for(kind.to_s) || Unavailable).new
  end

  def installed_definition_for(kind)
    Syrus::PluginRegistry.all_plugins.each do |manifest|
      Syrus::PluginRegistry.manifest_providers_for(manifest, :workflow_kinds).each do |provider|
        provider = provider.safe_constantize if provider.is_a?(String)
        next unless provider.respond_to?(:work_definitions)

        definition = Array(provider.work_definitions).find { |candidate| candidate.kind.to_s == kind }
        return definition if definition
      rescue StandardError => e
        Rails.logger.error("[WorkDefinitions] #{provider}.work_definitions failed: #{e.class}: #{e.message}")
      end
    end
    nil
  end
  private_class_method :installed_definition_for

  def landing_lock_kinds
    @landing_lock_kinds ||= kinds_matching(&:landing_lock?)
  end

  # The per-slot landing lock key for a Job, generalized from bare
  # repository locking to the Job's resolved delivery-track target ref
  # (`DeliveryPolicy#job_landing_branch`). Two Jobs whose resolved landing
  # branch matches share a key and serialize; Jobs landing to different
  # branches (e.g. a `hotfix` track straight to `main` alongside a
  # `default` track landing to `develop`) get distinct keys and can land
  # concurrently.
  #
  # Byte-for-byte compatibility for the common case: whenever the resolved
  # branch equals `Repository#default_branch` (true for every repository
  # that only has the implicit `default` track, and for any job whose
  # track happens to target the repository's actual default branch), this
  # returns the exact same key format Syrus has always used
  # (`"landing:repository:<id>"`) — no suffix. Only a job resolving to a
  # non-default branch gets the generalized, branch-suffixed key. Callers
  # that already resolved a `DeliveryPolicy` for this job's repository may
  # pass it via `policy:` to avoid a redundant `.syrus.yml` read.
  def landing_lock_key_for(job, policy: nil, lane: nil)
    return nil unless job&.repository_id

    repository = job.repository
    return landing_branch_lock_key(job.repository_id, nil, lane:) unless repository

    branch = (policy || DeliveryPolicy.for(repository: repository, job: job)).job_landing_branch(job)
    branch = nil if branch.blank? || branch == repository.default_branch
    landing_branch_lock_key(job.repository_id, branch, lane:)
  end

  # The lane lock key for a repository's landing branch; `branch` nil (or
  # the default branch) is the repository's own unsuffixed slot.
  def landing_branch_lock_key(repository_id, branch, lane: nil)
    # Lane 1 is the original slot and keeps its key byte for byte; further
    # lanes insert `:lane:<k>` before the branch suffix.
    key = "landing:repository:#{repository_id}"
    key = "#{key}:lane:#{lane.to_i}" if lane.to_i > 1
    branch.present? ? "#{key}:branch:#{branch}" : key
  end

  # Non-default landing branches of a repository that currently hold an
  # active landing unit in any lane.
  def active_landing_branches(repository)
    prefix = "landing:repository:#{repository.id}"
    WorkUnitLock.active
      .joins(:work_unit)
      .where(work_units: { state: WorkUnits::Ownership::ACTIVE_STATES, kind: landing_lock_kinds })
      .where("work_unit_locks.lock_key LIKE ?", "#{WorkUnitLock.sanitize_sql_like(prefix)}%:branch:%")
      .pluck(:lock_key)
      .filter_map { |key| key.match(/\A#{Regexp.escape(prefix)}(?::lane:\d+)?:branch:(.+)\z/)&.captures&.first }
      .uniq.sort
  end

  # Artifact on a landing Workflow naming the lane it landed in. Written only
  # for lanes above 1, so a single-lane repository's artifacts are unchanged.
  # Every site that recomputes a unit's lock keys already passes the
  # workflow's artifacts, which is how a lane-2 unit keeps asking for lane 2.
  LANDING_LANE_ARTIFACT = "landing_lane".freeze

  def landing_lane_count(repository)
    count = repository&.landing_concurrency.to_i
    count.clamp(Repository::LANDING_CONCURRENCY_RANGE.begin, Repository::LANDING_CONCURRENCY_RANGE.end)
  end

  # Every lane's lock key for the Job's landing branch, lane 1 first.
  def landing_lane_keys_for(job, policy: nil)
    return [] unless job&.repository_id

    (1..landing_lane_count(job.repository)).map { |lane| landing_lock_key_for(job, policy: policy, lane: lane) }
  end

  # Every lane key that could hold a unit for the Job's branch, including lanes
  # above the configured count: lowering `landing_concurrency` while higher
  # lanes are active leaves those units running until they drain, and they
  # still count against capacity and show in lane reporting.
  def landing_all_lane_keys_for(job, policy: nil)
    return [] unless job&.repository_id

    Repository::LANDING_CONCURRENCY_RANGE.map { |lane| landing_lock_key_for(job, policy: policy, lane: lane) }
  end

  # True once the units occupying lanes (configured or draining) reach the
  # configured count. `occupied_keys` lets a caller pass a precomputed set.
  def landing_capacity_full?(job, policy: nil, occupied_keys: nil)
    limit = landing_lane_count(job&.repository)
    keys = landing_all_lane_keys_for(job, policy: policy)
    return false if keys.empty?

    occupied = keys.count do |key|
      occupied_keys ? occupied_keys.include?(key) : WorkUnits::Ownership.active_for_lock_key?(key, kinds: landing_lock_kinds)
    end
    occupied >= limit
  end

  # The lane a lock key belongs to (1 for the unsuffixed original key).
  def landing_lane_for_key(lock_key)
    lock_key.to_s[/\Alanding:repository:\d+:lane:(\d+)/, 1]&.to_i || 1
  end

  # The artifacts a landing dispatch passes to claim `lane`; empty for lane 1.
  def landing_lane_artifacts(lane)
    lane.to_i > 1 ? { LANDING_LANE_ARTIFACT => lane.to_i } : {}
  end

  # The lowest-numbered lane whose lock no active landing unit holds, or nil
  # when every lane is occupied.
  def free_landing_lane_for(job, policy: nil)
    return nil if landing_capacity_full?(job, policy: policy)

    keys = landing_lane_keys_for(job, policy: policy)
    keys.each_with_index do |key, index|
      return index + 1 unless WorkUnits::Ownership.active_for_lock_key?(key, kinds: landing_lock_kinds)
    end
    nil
  end

  # Active landing units on the Job's branch, one per occupied lane.
  def active_landing_units_for(job, policy: nil)
    landing_all_lane_keys_for(job, policy: policy).filter_map do |key|
      WorkUnits::Ownership.active_unit_for_lock_key(key, kinds: landing_lock_kinds)
    end
  end

  # Occupancy of every lane on the Job's landing branch, for the reconciler,
  # stuck-Job explainer and admin views: which lanes are held and by which unit.
  def landing_lane_status_for(job, policy: nil)
    lane_status_for_keys(job&.repository, landing_all_lane_keys_for(job, policy: policy))
  end

  # The same lane occupancy for a repository branch without a sample Job;
  # `branch` nil is the default branch.
  def landing_branch_lane_status(repository, branch)
    keys = Repository::LANDING_CONCURRENCY_RANGE.map { |lane| landing_branch_lock_key(repository.id, branch, lane:) }
    lane_status_for_keys(repository, keys)
  end

  def lane_status_for_keys(repository, keys)
    configured = landing_lane_count(repository)
    keys.each_with_index.filter_map do |key, index|
      unit = WorkUnits::Ownership.active_unit_for_lock_key(key, kinds: landing_lock_kinds)
      next if unit.nil? && index >= configured

      {
        lane: index + 1,
        draining: index >= configured,
        lock_key: key,
        occupied: unit.present?,
        work_unit_id: unit&.id,
        work_unit_kind: unit&.kind,
        workflow_slug: unit&.workflow&.slug,
        member_job_ids: unit ? unit.work_unit_members.order(:id).pluck(:job_id) : []
      }
    end
  end

  # The Job that keeps `job` from starting a landing, or nil while a lane is
  # free. A landing is "in progress" only once every lane of the branch is
  # taken: by an active landing unit, or by a Job already in the landing state
  # that no unit accounts for (so a single-lane repository behaves exactly as
  # it always has).
  def landing_blocker_job_for(job, policy: nil)
    return nil if landing_lane_keys_for(job, policy: policy).empty?

    lane_count = landing_lane_count(job.repository)

    units = active_landing_units_for(job, policy: policy)
    unit_job = ->(unit) { unit.member_jobs.order(:id).first || unit.workflow&.job }
    return unit_job.call(units.first) if units.size >= lane_count

    accounted_job_ids = units.flat_map { |unit| unit.member_jobs.pluck(:id) + [ unit.workflow&.job_id ] }.compact
    base_key = landing_lock_key_for(job, policy: policy)
    orphans = Job.landing.where(repository_id: job.repository_id).where.not(id: accounted_job_ids).order(:id).select do |landing_job|
      landing_lock_key_for(landing_job, policy: policy) == base_key
    end
    return nil if units.size + orphans.size < lane_count

    orphans.first || unit_job.call(units.first)
  end

  # The key of the merge lock that serializes the final merge into a Job's
  # landing branch. It mirrors the landing lock key (same branch-suffix rule)
  # but is a separate lock: the landing slot covers a whole landing unit, the
  # merge lock only the last verify-merge-record sequence (see MergeLock).
  def merge_lock_key_for(job, policy: nil)
    landing_key = landing_lock_key_for(job, policy: policy)
    return nil unless landing_key

    landing_key.sub(/\Alanding:/, "merge:")
  end

  # The merge lock for a named branch: what a publish that writes straight to
  # a branch (hotfix sync, promotion) must hold, so it cannot move a landing
  # branch between a landing's head check and its merge (Lead L15, NY41).
  # Same key shape as merge_lock_key_for.
  def merge_lock_key_for_branch(repository, branch)
    return nil unless repository&.id

    key = "merge:repository:#{repository.id}"
    return key if branch.blank? || branch == repository.default_branch

    "#{key}:branch:#{branch}"
  end

  def landing_workflow_kinds
    @landing_workflow_kinds ||= definitions_matching { |definition| definition.landing_lock? && definition.first_class? }
      .map(&:workflow_trigger_kind)
      .uniq
      .freeze
  end

  # Workflow trigger kinds that carry a Job's own work, as opposed to the work
  # that runs the instance: landing (which drains the queue), main-branch
  # health and repairs (which unblock it), and the child workflows of an
  # attempt that is already under way. Derived from the same properties the
  # rest of the policy layer uses, so a new kind lands on the right side of it
  # without being named here.
  #
  # This is the set a work-in-progress limit may ration: holding back anything
  # else would be throttling the machinery that lets Job work finish.
  def job_work_workflow_kinds
    @job_work_workflow_kinds ||= definitions_matching { |definition|
      definition.first_class? && !definition.landing_lock? && !definition.agent_concurrency_exempt?
    }.map(&:workflow_trigger_kind)
      .compact
      .uniq
      .freeze
  end

  def first_class_work_unit_kinds
    @first_class_work_unit_kinds ||= kinds_matching(&:first_class?)
  end

  def landing_work_unit_kinds
    @landing_work_unit_kinds ||= kinds_matching { |definition| definition.landing_lock? && definition.first_class? }
  end

  def epic_wide_kinds
    @epic_wide_kinds ||= kinds_matching { |definition| definition.scope == "epic" && definition.first_class? }
  end

  def ci_failure_blocking_kinds
    @ci_failure_blocking_kinds ||= kinds_matching(&:blocks_ci_failure?)
  end

  def active_repair_work_kinds
    @active_repair_work_kinds ||= kinds_matching(&:active_repair_work?)
  end

  def retry_workflow_attempt_kinds
    @retry_workflow_attempt_kinds ||= kinds_matching(&:retry_workflow_attempt?)
  end

  def recoverable_cancelled_workflow_kinds
    @recoverable_cancelled_workflow_kinds ||= kinds_matching(&:recoverable_cancelled_workflow?)
  end

  def layered_auto_repair_suppressed_kinds
    @layered_auto_repair_suppressed_kinds ||= kinds_matching(&:suppresses_layered_auto_repair?)
  end

  def landing_validation_prefetch_source_kinds
    @landing_validation_prefetch_source_kinds ||= kinds_matching(&:landing_validation_prefetch_source?)
  end

  def landing_validation_child_kinds
    @landing_validation_child_kinds ||= kinds_matching(&:landing_validation_child?)
  end

  def agent_concurrency_exempt_kinds
    @agent_concurrency_exempt_kinds ||= kinds_matching(&:agent_concurrency_exempt?)
  end

  def lifecycle_managed_workflow_kinds
    @lifecycle_managed_workflow_kinds ||= definitions_matching(&:manages_own_job_lifecycle?)
      .map(&:workflow_trigger_kind)
      .uniq
      .freeze
  end

  def child_kinds_for(parent_kind)
    load_definitions
    registry.values
      .map(&:new)
      .select { |definition| definition.parent_kind == parent_kind.to_s }
      .map(&:kind)
      .freeze
  end

  def family_kinds_for(kind)
    [ kind.to_s, *child_kinds_for(kind) ].uniq.freeze
  end

  def workflow_trigger_kinds_for(kinds)
    Array(kinds)
      .map { |kind| registry[kind.to_s]&.new&.workflow_trigger_kind }
      .compact
      .uniq
      .freeze
  end

  def kinds_for_workflow_trigger(trigger_kind)
    trigger_kind = trigger_kind.to_s
    definitions_matching { |definition| definition.workflow_trigger_kind == trigger_kind }
      .map(&:kind)
      .freeze
  end

  def landing_validation_child_kind_for(parent_kind)
    load_definitions
    registry.values
      .map(&:new)
      .find { |definition| definition.parent_kind == parent_kind.to_s && definition.landing_validation_child? }
      &.kind
  end

  def registry
    load_definitions
    generation = Syrus::PluginRegistry.generation
    return @registry if defined?(@registry) && @registry && @registry_generation == generation

    provided = plugin_definitions.to_set
    reset_registry!
    @registry_generation = generation
    @registry = WorkDefinitions::Base.descendants
      .select { |definition| definition.plugin.nil? || provided.include?(definition) }
      .index_by(&:kind)
      .freeze
  end

  # Plugin-owned definitions, resolved through the registry so a disabled
  # plugin contributes none. Referencing the classes here is also what
  # autoloads them, which is what puts them in Base.descendants at all.
  def plugin_definitions
    Syrus::PluginRegistry.providers_for(:workflow_kinds).flat_map do |provider|
      next [] unless provider.respond_to?(:work_definitions)

      Array(provider.work_definitions)
    rescue StandardError => e
      Rails.logger.error("[WorkDefinitions] #{provider}.work_definitions failed: #{e.class}: #{e.message}")
      []
    end
  end

  def reset_registry!
    %i[
      @registry
      @registry_generation
      @landing_lock_kinds
      @first_class_work_unit_kinds
      @landing_workflow_kinds
      @landing_work_unit_kinds
      @epic_wide_kinds
      @ci_failure_blocking_kinds
      @active_repair_work_kinds
      @retry_workflow_attempt_kinds
      @recoverable_cancelled_workflow_kinds
      @layered_auto_repair_suppressed_kinds
      @landing_validation_prefetch_source_kinds
      @landing_validation_child_kinds
      @agent_concurrency_exempt_kinds
      @lifecycle_managed_workflow_kinds
    ].each do |ivar|
      remove_instance_variable(ivar) if instance_variable_defined?(ivar)
    end
  end

  # `require_dependency` searches every autoload path with `File.file?` on
  # each call, even for a file already loaded, and `registry` -- consulted on
  # every dispatch -- called this every time: about a tenth of a simulated
  # tick. Load once. A code reload replaces this module, which resets the flag.
  def load_definitions
    return if @definitions_loaded

    require_dependency "work_definitions/base"
    require_dependency "work_definitions/built_ins"
    require_dependency "work_definitions/registry_validator"
    @definitions_loaded = true
  end

  def validate_registry!
    errors = WorkDefinitions::RegistryValidator.call
    return true if errors.empty?

    raise Error, errors.map(&:message).join("; ")
  end

  def kinds_matching(&predicate)
    definitions_matching(&predicate)
      .map(&:kind)
      .freeze
  end

  def definitions_matching(&predicate)
    registry.values
      .map(&:new)
      .select(&predicate)
  end
end
