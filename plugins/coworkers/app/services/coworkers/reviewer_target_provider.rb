class Coworkers::ReviewerTargetProvider
  include Syrus::Plugin::ReviewerTargetProvider

  def self.target_type = "coworker"

  def self.options(user:, repository: nil)
    eligible_scope(user: user, repository: repository).order(:name, :id).map do |coworker|
      { type: target_type, reference: coworker.id.to_s, display: display(coworker) }
    end
  end

  def self.resolve(reference:, owner:, repository:)
    coworker = eligible_scope(user: owner, repository: repository).find(Integer(reference))
    { type: target_type, reference: coworker.id.to_s, display: display(coworker), record: coworker }
  rescue ArgumentError, TypeError
    raise ActiveRecord::RecordNotFound, "coworker reviewer reference is invalid"
  end

  def self.eligible_scope(user:, repository:)
    scope = Coworkers::Coworker.where(owner_user: user, state: "active")
    return scope if repository.nil?

    grant_ids = Coworkers::Grant.where(capability: "code.read")
      .select { |grant| Array(grant.scope).map(&:to_i).include?(repository.id) }
      .map(&:coworker_id)
    scope.where(id: grant_ids)
  end

  def self.display(coworker)
    { "name" => coworker.name, "handle" => coworker.handle, "role_summary" => coworker.role_summary.to_s }
  end

  private_class_method :eligible_scope, :display
end
