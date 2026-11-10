class Coworkers::PushGuard
  class ForeignRef < ArgumentError; end

  def initialize(coworker:)
    @coworker_id = coworker.id
    @handle = coworker.handle.to_s
  end

  def allow!(ref)
    branch = ref.to_s.delete_prefix("refs/heads/")
    allowed = branch == "coworkers/#{@handle}" ||
      branch.match?(%r{\Acoworkers/chat/#{@coworker_id}-\d+\z}) ||
      branch.match?(%r{\Acoworkers/run/#{@coworker_id}-\d+\z}) ||
      branch.match?(%r{\Acoworkers/archived/#{Regexp.escape(@handle)}-\d{4}-\d{2}-\d{2}(?:-\d+)?\z})
    raise ForeignRef, "coworker pushes may only target its home, chat, run, or archive refs" unless allowed

    branch
  end

  # Recovery refs preserve both merge parents and a failed resolution attempt;
  # they are never the persistent home branch.
  def allow_recovery!(ref)
    branch = ref.to_s.delete_prefix("refs/heads/")
    unless branch.match?(%r{\Acoworker-recovery/#{@coworker_id}-[A-Za-z0-9-]+/(?:home|source|attempt)\z})
      raise ForeignRef, "coworker recovery pushes may only target its own recovery refs"
    end

    branch
  end
end
