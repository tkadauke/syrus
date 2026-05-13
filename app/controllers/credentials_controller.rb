class CredentialsController < ApplicationController
  def edit
    @user = Current.user
    # Show the freshly-minted token to the operator ONCE — flash
    # carries it across the post-create redirect, then it's gone.
    @new_api_token = flash[:new_api_token]
  end

  def update
    attrs = credentials_params.to_h.reject { |_, v| v.blank? }
    if Current.user.update(attrs)
      redirect_to edit_credentials_path, notice: "Credentials updated."
    else
      @user = Current.user
      render :edit, status: :unprocessable_entity
    end
  end

  # Admin-only: rotate (or first-time generate) the API token. We
  # store it deterministic-encrypted and never display it again,
  # so the operator must record it on this round-trip or rotate.
  def rotate_api_token
    unless Current.user.admin?
      redirect_to edit_credentials_path, alert: "API token is admin-only." and return
    end
    flash[:new_api_token] = Current.user.generate_api_token!
    redirect_to edit_credentials_path, notice: "API token rotated. Copy it now — it won't be shown again."
  end

  def revoke_api_token
    unless Current.user.admin?
      redirect_to edit_credentials_path, alert: "API token is admin-only." and return
    end
    Current.user.revoke_api_token!
    redirect_to edit_credentials_path, notice: "API token revoked."
  end

  private

  def credentials_params
    params.expect(user: [ :name, :github_handle, :agent_provider, :claude_oauth_token, :codex_auth_mode,
                          :codex_api_key, :codex_auth_json, :github_token,
                          :agent_max_turns, :scheduling_paused, :telegram_chat_id ])
  end
end
