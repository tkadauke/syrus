module ChatGoalActions
  def show_goal
    chat_session = find_chat_session

    render json: { active_goal: chat_goal_json(chat_session.active_goal) }
  end

  def upsert_goal
    chat_session = find_chat_session

    goal = nil
    chat_session.with_lock do
      goal = chat_session.active_goal
      goal_attrs = chat_goal_attributes(chat_session, existing_goal: goal)
      next if performed?

      if goal
        goal.update!(goal_attrs)
        goal.resume! if goal.paused?
      else
        goal = chat_session.chat_goals.create!(goal_attrs.merge(user: chat_session.user))
      end
    end
    return if performed?

    render json: chat_payload(chat_session.reload, message: "Goal updated.")
  rescue ActiveRecord::RecordInvalid => e
    render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
  rescue ActiveRecord::RecordNotUnique
    render_error("validation_failed", "Chat already has an active goal.", status: :unprocessable_content)
  end

  def pause_goal
    mutate_goal!("Goal paused.") { |goal| goal.pause! }
  end

  def resume_goal
    mutate_goal!("Goal resumed.") do |goal|
      goal.resume!
      ChatGoalWakeup.publish_control!(goal, action: "resume")
    end
  end

  def stop_goal
    mutate_goal!("Goal stopped.") { |goal| goal.stop!(reason: terminal_reason_param("stopped"), details: terminal_details_param) }
  end

  def complete_goal
    mutate_goal!("Goal completed.") { |goal| goal.complete!(reason: terminal_reason_param("completed"), details: terminal_details_param) }
  end

  def block_goal
    reason = terminal_reason_param(nil)
    if reason.blank?
      render_error("validation_failed", "reason is required.", status: :unprocessable_content)
      return
    end

    mutate_goal!("Goal blocked.") { |goal| goal.block!(reason: reason, details: terminal_details_param) }
  end

  private

  def mutate_goal!(message)
    chat_session = find_chat_session
    goal = chat_session.active_goal
    unless goal
      render_error("not_found", "Active goal was not found.", status: :not_found)
      return
    end

    yield goal
    render json: chat_payload(chat_session.reload, message: message)
  rescue ActiveRecord::RecordInvalid => e
    render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
  end

  def chat_goal_attributes(chat_session, existing_goal:)
    goal_params = params[:goal].presence || params
    creating = existing_goal.nil?
    prompt = goal_params[:prompt].to_s.strip if goal_params.key?(:prompt)
    if creating && prompt.blank?
      render_error("validation_failed", "prompt is required.", status: :unprocessable_content)
      return {}
    end

    mode = chat_session.mode.presence || "planning"
    return {} unless goal_mode_available?(mode)

    repository = chat_goal_repository(goal_params)
    return {} if performed?

    repository ||= existing_goal&.repository || chat_session.repository
    attrs = { mode_snapshot: chat_goal_mode_snapshot(chat_session, repository: repository) }
    attrs[:prompt] = prompt if goal_params.key?(:prompt)
    attrs[:completion_condition] = goal_params[:completion_condition].to_s.strip.presence if goal_params.key?(:completion_condition)
    attrs[:approval_policy] = goal_params[:approval_policy].to_s.strip.presence || "manual" if goal_params.key?(:approval_policy) || creating
    attrs[:auto_file_proposals] = boolean_param(goal_params[:auto_file_proposals]) || false if goal_params.key?(:auto_file_proposals) || creating
    attrs[:auto_submit_jobs] = boolean_param(goal_params[:auto_submit_jobs]) || false if goal_params.key?(:auto_submit_jobs) || creating
    attrs[:repository] = repository if repository
    attrs
  end

  def chat_goal_mode_snapshot(chat_session, repository:)
    {
      "mode" => chat_session.mode.presence || "planning",
      "chat_provider" => chat_session.chat_provider,
      "chat_model" => chat_session.chat_model,
      "repository_id" => repository&.id
    }
  end

  def chat_goal_repository(goal_params)
    repository_id = goal_params[:repository_id].presence
    return nil unless repository_id

    Repository.accessible_to(Current.user).active.find(repository_id)
  rescue ActiveRecord::RecordNotFound
    render_error("not_found", "Repository was not found.", status: :not_found)
    nil
  end

  def goal_mode_available?(mode)
    if mode == "coding" && !Feature.coding_mode_enabled?
      render_error("feature_disabled", "Coding Mode is not enabled on this instance.", status: :unprocessable_content)
      return false
    end
    if mode == "local" && !Feature.local_mode_enabled?
      render_error("validation_failed", "Local mode is not enabled.", status: :unprocessable_content)
      return false
    end

    true
  end

  def boolean_param(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def terminal_reason_param(default)
    goal_params = params[:goal].presence || params
    goal_params[:reason].to_s.strip.presence || default
  end

  def terminal_details_param
    goal_params = params[:goal].presence || params
    details = goal_params[:details]
    details.respond_to?(:to_unsafe_h) ? details.to_unsafe_h : details
  end
end
