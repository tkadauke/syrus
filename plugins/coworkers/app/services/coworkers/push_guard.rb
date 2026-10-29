class Coworkers::PushGuard
  class Rejected < StandardError; end

  def initialize(coworker: nil, home_branch: nil)
    @coworker = coworker
    @home_branch = home_branch
  end

  def validate!(*refspecs)
    refspecs.flatten.each do |refspec|
      branch = destination_branch(refspec)
      raise Rejected, "coworker pushes must target refs under coworkers/" unless branch&.start_with?("coworkers/")
      next unless @coworker
      next if branch == (@home_branch || "coworkers/#{@coworker.handle}")
      next if branch.match?(%r{\Acoworkers/chat/#{@coworker.id}-\d+\z})

      raise Rejected, "coworker push rejected for foreign ref #{branch}"
    end
  end

  private

  def destination_branch(refspec)
    destination = refspec.to_s.split(":", 2).last
    destination&.delete_prefix("refs/heads/")
  end
end
