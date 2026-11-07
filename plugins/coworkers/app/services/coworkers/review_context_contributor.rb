class Coworkers::ReviewContextContributor
  include Syrus::Plugin::ReviewContextContributor

  def self.target_type = "coworker"

  def self.prepare(target:, run:, evidence:, criteria:)
    coworker = resolve(target, run)
    context = coworker.prepare_review_context!(run:, evidence:, criteria:)
    {
      manifest: context.manifest,
      restricted_text: coworker.review_context_prompt(context),
      persistence_token: context.id.to_s
    }
  end

  def self.persist(target:, run:, context:, verdict:, update:)
    coworker = resolve(target, run)
    persisted = coworker.finalize_review_memory!(
      run:,
      key_learning: update.to_h.deep_stringify_keys.fetch("key_learning"),
      verdict:
    )
    {
      owner: "coworkers",
      type: "review_memory",
      key: persisted.id.to_s,
      version: persisted.updated_at.to_i,
      persisted_at: persisted.updated_at.iso8601
    }
  end

  def self.tool_set(_target) = Coworkers::ReviewToolSet

  def self.resolve(target, run)
    ReviewerTargets.resolve(
      target,
      owner: run.job.owner_user || run.job.user,
      repository: run.job.repository
    ).fetch(:record)
  end
  private_class_method :resolve
end
