module Decisions
  # Turns a Problem into a Decision, or declines to (workflow-engine-v3 B2/B3).
  #
  # Two things stop the queue from growing without bound:
  #
  #   * an open Decision with the same signature is reused, so the tenth
  #     occurrence of one problem is one row, not ten;
  #   * a prior decision on the same signature -- still in scope and not
  #     expired -- answers the question without asking anyone again. This is
  #     what makes human attention compound rather than merely reformat.
  #
  # Scope is a repository by default, never global: a dismissal that was right
  # for one project is not evidence about another. `expires_at` is the second
  # guardrail -- a dismissal that made sense against one base revision should
  # not silently outlive it.
  class Opener
    Result = Data.define(:decision, :prior, :created) do
      def created? = created
      def answered_by_prior? = prior.present?
    end

    def self.call(...) = new(...).call

    def initialize(problem:, title:, queue: "operator", urgency: "normal", summary: nil,
                   adjudication: nil, actions: [], repository: nil, job: nil,
                   workflow: nil, step: nil, user: nil, expires_at: nil)
      @problem = problem
      @title = title
      @queue = queue.to_s
      @urgency = urgency.to_s
      @summary = summary
      @adjudication = adjudication
      @actions = actions
      @repository = repository || job&.repository || workflow&.job&.repository
      @job = job
      @workflow = workflow
      @step = step
      @user = user || job&.user
      @expires_at = expires_at
    end

    def call
      prior = matching_prior_decision
      return Result.new(decision: nil, prior: prior, created: false) if prior

      existing = open_duplicate
      return Result.new(decision: existing, prior: nil, created: false) if existing

      Result.new(decision: create!, prior: nil, created: true)
    end

    private

    attr_reader :problem, :repository, :job, :workflow, :step, :user

    def signature = @signature ||= Decisions::Signature.for(problem)

    # A decision already made about this exact problem, in this repository,
    # that has not expired.
    def matching_prior_decision
      Decision.where(signature: signature, state: "decided")
              .where(repository_id: repository&.id)
              .unexpired
              .order(decided_at: :desc)
              .first
    end

    def open_duplicate
      Decision.open_decisions.where(signature: signature, repository_id: repository&.id).first
    end

    def create!
      Decision.create!(
        problem_code: problem.code,
        signature: signature,
        evidence: problem.evidence,
        adjudication: @adjudication&.to_h,
        title: @title,
        summary: @summary,
        queue: @queue,
        urgency: @urgency,
        actions: @actions,
        repository: repository,
        job: job,
        workflow: workflow,
        step: step,
        user: user,
        expires_at: @expires_at
      )
    end
  end
end
