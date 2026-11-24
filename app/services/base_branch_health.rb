# Core's only view of base-branch health tracking and repair. Whatever plugin
# provides :base_branch_health answers; with none enabled every call returns a
# "nothing known" value (no checks, no repair Jobs, no polling), so workflows
# start, landing proceeds and no health state is read or written.
module BaseBranchHealth
  # Stands in for a relation of records no provider owns. Chains like a relation
  # and is always empty; writing raises because there is nowhere to write.
  class EmptyRecords
    def self.instance = @instance ||= new

    def where(*, **) = self
    def not(*, **) = self
    def order(*) = self
    def limit(*) = self
    def recent = self
    def to_a = []
    def pluck(*) = []
    def map(*) = []
    def first = nil
    def last = nil
    def exists? = false
    def none? = true
    def any? = false
    def empty? = true
    def blank? = true
    def present? = false
    def detect(*) = nil
    def create!(*, **) = raise(NotImplementedError, "no base-branch health provider is enabled")
    def respond_to_missing?(*) = true
    def method_missing(_name, *, **) = self
  end

  def self.provider
    Syrus::PluginRegistry.providers_for(:base_branch_health).first
  end

  def self.monitoring_enabled?(repository)
    ask(:monitoring_enabled?, repository, default: false)
  end

  def self.poll_later(repository_id, manual: false)
    ask(:poll_later, repository_id, manual: manual, default: nil)
  end

  def self.repair_job?(job)
    ask(:repair_job?, job, default: false)
  end

  def self.repair_job_implemented(job)
    ask(:repair_job_implemented, job, default: nil)
  end

  def self.repair_job_closed(job)
    ask(:repair_job_closed, job, default: nil)
  end

  def self.ensure_repair!(repository)
    ask(:ensure_repair!, repository, default: nil)
  end

  def self.health_changed!(repository)
    ask(:health_changed!, repository, default: nil)
  end

  def self.stuck_repair_job(repository, now: Time.current)
    ask(:stuck_repair_job, repository, now: now, default: nil)
  end

  # CI health values that count as a settled verdict about a base commit.
  def self.settled_ci_health
    ask(:settled_ci_health, default: [])
  end

  def self.checks
    ask(:checks, default: EmptyRecords.instance)
  end

  def self.concern_reports
    ask(:concern_reports, default: EmptyRecords.instance)
  end

  def self.ask(operation, *args, default:, **kwargs)
    provider = self.provider
    return default unless provider&.respond_to?(operation)

    result = Syrus::PluginInvocation.call(
      extension_point: :base_branch_health, provider: provider, operation: operation, on_decline: default
    ) { provider.public_send(operation, *args, **kwargs) }
    Syrus::PluginInvocation.value(result)
  end
  private_class_method :ask
end
