module TurboHelper
  def safe_turbo_frame(id, **options, &block)
    turbo_frame_tag(id, **{ target: "_top" }.merge(options), &block)
  end
end
