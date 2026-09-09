class Step
  module PlacementPolicy
    PINNED_WORKFLOW_WORKSPACE = "pinned_workflow_workspace".freeze
    IMMUTABLE_SOURCE_CHECKOUT = "immutable_source_checkout".freeze
    CONTROL_PLANE = "control_plane".freeze
    EXTERNAL_CONTEXT = "external_context".freeze

    VALUES = [
      PINNED_WORKFLOW_WORKSPACE,
      IMMUTABLE_SOURCE_CHECKOUT,
      CONTROL_PLANE,
      EXTERNAL_CONTEXT
    ].freeze
  end
end
