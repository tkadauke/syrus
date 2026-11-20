require "rails_helper"
require "prism"

# Step handlers used to close their Job directly with `close_with_reason!`,
# and a missing `may_close?` guard could leave `closure_reason` set on a Job
# that never closed. Closing mid-Workflow also let later Steps start on a
# closed Job. Steps now record the closure on their Workflow
# (`request_job_closure!`) and JobClosure applies it when the Workflow
# finishes, so no Steps:: handler may call `close_with_reason!` at all.
RSpec.describe "Steps:: handlers close Jobs only through their Workflow" do
  CLOSE_GUARD_SOURCES = Dir[Rails.root.join("app/services/steps/**/*.rb")] +
            Dir[Rails.root.join("plugins/*/app/services/steps/**/*.rb")]

  def self.calls_named(name)
    CLOSE_GUARD_SOURCES.flat_map do |path|
      found = []
      collect = lambda do |node|
        next unless node.is_a?(Prism::Node)

        found << "#{Pathname(path).relative_path_from(Rails.root)}:#{node.location.start_line}" if node.is_a?(Prism::CallNode) && node.name.to_s == name
        node.compact_child_nodes.each { |child| collect.call(child) }
      end
      collect.call(Prism.parse(File.read(path)).value)
      found
    end
  end

  it "never calls close_with_reason! directly from a step handler" do
    direct = self.class.calls_named("close_with_reason!")

    expect(direct).to be_empty,
      "step handlers must request closure with request_job_closure!, not close the Job mid-Workflow:\n  #{direct.join("\n  ")}"
  end

  it "actually finds the step handlers' closure requests, so a rename cannot quietly empty this check" do
    expect(self.class.calls_named("request_job_closure!")).not_to be_empty
  end
end
