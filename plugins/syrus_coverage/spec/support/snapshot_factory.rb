# Test data for the plugin's own tables. Lives with the plugin rather than in
# core's spec/support/factories.rb so core's factories name nothing it does
# not own.
module SyrusCoverageFactories
  module_function

  def snapshot(**attrs)
    job = attrs[:job] || Factories.job
    SyrusCoverage::Snapshot.create!({
      repository: attrs[:repository] || job.repository,
      workflow: attrs[:workflow] || job.workflows.first,
      job: job,
      sha: "abc#{SecureRandom.hex(3)}",
      branch: "main"
    }.merge(attrs))
  end
end
