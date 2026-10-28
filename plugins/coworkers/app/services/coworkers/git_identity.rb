class Coworkers::GitIdentity
  def initialize(name:, handle:)
    @name = name
    @handle = handle
  end

  def git_name = "#{@name} (@#{@handle})"
  def git_email = "#{@handle}@coworkers.syrus.invalid"
end
