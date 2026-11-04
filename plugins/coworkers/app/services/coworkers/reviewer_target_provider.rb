class Coworkers::ReviewerTargetProvider
  include Syrus::Plugin::ReviewerTargetProvider

  reviewer_target_type "coworker"

  class << self
    def resolve_reviewer_target(reference:, user:, repository:)
      coworker = Coworkers::Coworker.find_by(id: opaque_id(reference), owner_user_id: user.id, state: "active")
      return unless coworker
      return unless RepositoryPolicy.new(user, repository).show?

      coworker
    end

    def reviewer_target_options(user:, repository: nil)
      return [] if repository && !RepositoryPolicy.new(user, repository).show?

      Coworkers::Coworker.where(owner_user: user, state: "active").order(:name, :id).map do |coworker|
        {
          type: reviewer_target_type,
          reference: opaque_reference(coworker),
          display_snapshot: reviewer_target_snapshot(coworker)
        }
      end
    end

    def reviewer_target_snapshot(coworker)
      { name: coworker.name, handle: coworker.handle, role_summary: coworker.role_summary }.compact
    end

    private

    def opaque_reference(coworker) = "coworker:#{coworker.id}"

    def opaque_id(reference)
      match = reference.to_s.match(/\Acoworker:(\d+)\z/)
      match && match[1]
    end
  end
end
