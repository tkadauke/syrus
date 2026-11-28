module Coworkers
  class JobAutonomy
    CAPABILITIES = {
      "propose_job" => "coworker.jobs.propose",
      "approve_job" => "coworker.jobs.approve",
      "submit_chat_feedback" => "coworker.jobs.feedback",
      "cancel_job" => "coworker.jobs.cancel",
      "retry_job" => "coworker.jobs.retry"
    }.freeze

    Decision = Data.define(:allowed, :rule) do
      def allowed? = allowed
    end

    def initialize(coworker)
      @coworker = coworker
    end

    def authorize(tool_name:, repository:, job: nil)
      return Decision.new(false, nil) unless CAPABILITIES.key?(tool_name.to_s)
      return Decision.new(false, nil) if job && job.filed_by_coworker_id != coworker.id

      rule = coworker.permission_rules.rules.where(policy: "allow").find do |candidate|
        unversioned(candidate.capability) == CAPABILITIES.fetch(tool_name.to_s) &&
          repository_ids(candidate).include?(repository.id)
      end
      Decision.new(rule.present?, rule)
    end

    private

    attr_reader :coworker

    def repository_ids(rule)
      scope = rule.provenance["coworker_scope"]
      scope = rule.resource_scope["repository_id"] if scope.nil?
      Array(scope).filter_map { |value| Integer(value, exception: false) }
    end

    def unversioned(value) = value.to_s.sub(/@v\d+\z/, "")
  end
end
