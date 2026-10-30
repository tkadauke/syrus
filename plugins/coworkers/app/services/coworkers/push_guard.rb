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
end
