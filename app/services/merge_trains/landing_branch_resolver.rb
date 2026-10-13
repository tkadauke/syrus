module MergeTrains
  class LandingBranchResolver
    def self.call(repository:, members:)
      new(repository: repository, members: members).call
    end

    Result = Data.define(:base_branch, :reason) do
      def ok? = reason.nil?
    end

    def initialize(repository:, members:)
      @repository = repository
      @members = members
    end

    def call
      branch_groups = members.group_by { |job| policy.job_landing_branch(job).presence || repository.default_branch }
      return Result.new(base_branch: branch_groups.keys.first || repository.default_branch, reason: nil) if branch_groups.size <= 1

      Result.new(base_branch: nil, reason: mixed_branch_reason(branch_groups))
    end

    private

    attr_reader :repository, :members

    def policy
      @policy ||= DeliveryPolicy.for(repository: repository)
    end

    def mixed_branch_reason(branch_groups)
      branches = branch_groups.keys.sort.join(", ")
      "merge train members target multiple landing branches: #{branches}"
    end
  end
end
