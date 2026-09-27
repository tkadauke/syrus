module OperatorBriefing
  extend Syrus::PluginApi

  SEVERITIES = %w[informational fyi decision_required attention_debt].freeze

  syrus_plugin "operator_briefing" do
    display_name "Operator Briefing"
    description "Data-layer groundwork for operator briefing decision surfaces."
    long_description "Operator Briefing stores briefing items that later generation work can synthesize into the operator-facing briefing."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/operator_briefing.svg"
    author "Thomas Kadauke"
    category "observability"
    default_enabled false
    disableable true
    depends_on [ "design_docs" ]
  end
end
