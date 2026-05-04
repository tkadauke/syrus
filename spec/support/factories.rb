module Factories
  module_function

  def user(**attrs)
    User.create!({ email_address: "user-#{SecureRandom.hex(4)}@example.com", password: "supersecret" }.merge(attrs))
  end

  def repository(**attrs)
    Repository.create!({
      user: attrs[:user] || user,
      owner: "acme",
      name: "widgets-#{SecureRandom.hex(2)}"
    }.merge(attrs))
  end

  def cron_template(**attrs)
    CronTemplate.create!({
      user: attrs[:user] || user,
      name: "Weekly maintenance",
      prompt: "Keep things tidy.",
      cron_expression: "0 9 * * 1",
      pr_pileup_policy: "skip"
    }.merge(attrs))
  end

  def job(**attrs)
    repo = attrs[:repository] || repository
    Job.create!({
      user: repo.user,
      repository: repo,
      issue_number: 42
    }.merge(attrs))
  end

  # Returns the auto-created initial Run on a fresh Job, or builds an
  # extra Run on an existing Job (use `job:` and pass a different
  # trigger_kind, e.g. trigger_kind: "pr_comment").
  def run(**attrs)
    if attrs[:job]
      Run.create!({ trigger_kind: "initial" }.merge(attrs))
    else
      job(**attrs).initial_run
    end
  end
end

RSpec.configure do |config|
  config.include Factories
end
