# Base class for the app-facing Repository/Job/Epic policy layer. Global
# admins (User#admin?) bypass every policy in this hierarchy.
class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  def admin?
    user&.admin? || false
  end

  class Scope
    attr_reader :user, :scope

    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      raise NoMethodError, "You must define #resolve in #{self.class}"
    end

    private

    def admin?
      user&.admin? || false
    end
  end
end
