module SyrusBrowser
  # Declares how a `visual_review_screenshot` typed artifact (submitted via
  # the core `submit_visual_artifact` MCP tool) should render in the job
  # detail UI's Artifacts tab. After-only for this Epic — a single image,
  # not a before/after comparison (that's :before_after_diff, for a later
  # Epic once a real "before" image exists).
  class ImageDiffRenderer
    def self.artifact_type = "visual_review_screenshot"
    def self.renderer_type = :image_diff
  end
end
