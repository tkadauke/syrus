module Factories
  module_function

  def user(**attrs)
    User.create!({ email_address: "user-#{SecureRandom.hex(4)}@example.com", password: "supersecret" }.merge(attrs))
  end

  def codex_auth_json(access_token: "access-token", refresh_token: "refresh-token", id_token: "id-token")
    JSON.generate(
      "auth_mode" => "chatgpt",
      "tokens" => {
        "id_token" => id_token,
        "access_token" => access_token,
        "refresh_token" => refresh_token
      },
      "last_refresh" => "2026-05-08T00:00:00Z"
    )
  end

  def repository(**attrs)
    Repository.create!({
      user: attrs[:user] || user,
      owner: "acme",
      name: "widgets-#{SecureRandom.hex(6)}"
    }.merge(attrs))
  end

  def epic(**attrs)
    repo = attrs[:repository] || repository(user: attrs[:user] || user)
    Epic.create!({
      user: attrs[:user] || repo.user,
      repository: repo,
      title: "Epic #{SecureRandom.hex(2)}"
    }.merge(attrs))
  end

  def installation(**attrs)
    Installation.create!({
      user: attrs[:user] || user,
      github_installation_id: SecureRandom.random_number(1_000_000_000),
      account_login: "acme",
      account_id: SecureRandom.random_number(1_000_000_000),
      account_type: "Organization",
      installed_at: Time.current
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
    owner = attrs.key?(:user) ? attrs[:user] : repo.user
    owner_attrs = attrs.key?(:owner_user) || attrs.key?(:owner_user_id) ? {} : { owner_user: owner }
    job = Job.create!({
      user: owner,
      repository: repo,
      issue_number: 42
    }.merge(owner_attrs).merge(attrs))
    job.advance_after_triage! if job.may_advance_after_triage?
    job.association(:workflows).reset
    job.association(:runs).reset
    job
  end

  # Creates only the Job row, without the model's issue-job after_create
  # workflow. Use this for list/filter specs that don't assert workflow or
  # run behavior; use `job` when the initial Workflow/Run graph matters.
  def job_record(**attrs)
    repo = attrs[:repository] || repository(user: attrs[:user] || user)
    desired_state = attrs.key?(:state) ? attrs[:state] : "queued"
    owner = attrs.key?(:user) ? attrs[:user] : repo.user
    owner_attrs = attrs.key?(:owner_user) || attrs.key?(:owner_user_id) ? {} : { owner_user: owner }

    create_attrs = {
      user: owner,
      repository: repo,
      issue_number: 42
    }.merge(owner_attrs).merge(attrs).merge(state: "closed")

    job = Job.create!(create_attrs)
    if desired_state != "closed"
      updates = { state: desired_state }
      updates[:finished_at] = attrs[:finished_at] if attrs.key?(:finished_at)
      updates[:closure_reason] = attrs[:closure_reason] if attrs.key?(:closure_reason)
      job.update_columns(updates)
      job.reload
    end
    job
  end

  def job_pin(**attrs)
    pin_user = attrs[:user]
    pinned_job = attrs[:job] || job(repository: repository(user: pin_user || user))
    JobPin.create!({
      user: pin_user || pinned_job.user,
      job: pinned_job
    }.merge(attrs))
  end

  def tag(**attrs)
    Tag.create!({
      user: attrs[:user] || user,
      name: "tag-#{SecureRandom.hex(2)}",
      color: "gray"
    }.merge(attrs))
  end

  def coverage_snapshot(**attrs)
    j = attrs[:job] || job
    CoverageSnapshot.create!({
      repository: attrs[:repository] || j.repository,
      workflow:   attrs[:workflow]   || j.workflows.first,
      job:        j,
      sha:        "abc#{SecureRandom.hex(3)}",
      branch:     "main"
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
