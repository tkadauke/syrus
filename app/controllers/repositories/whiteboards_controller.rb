class Repositories::WhiteboardsController < ApplicationController
  before_action :load_repository
  before_action :load_chat_session, if: :chat_whiteboard_request?
  before_action :load_repository_whiteboard, unless: :chat_whiteboard_request?

  def show
    render json: whiteboard_payload
  end

  def update
    if chat_whiteboard_request?
      update_chat_whiteboard
    else
      update_repository_whiteboard
    end
  end

  private

  def load_repository
    @repository = Current.user.repositories.find(params[:repository_id])
  end

  def chat_whiteboard_request?
    params[:chat_id].present?
  end

  def load_chat_session
    @chat_session = @repository.chat_sessions.find(params[:chat_id])
  end

  def load_repository_whiteboard
    @repository_whiteboard = @repository.repository_whiteboard || @repository.create_repository_whiteboard!
  end

  def whiteboard_elements
    elements = params.fetch(:elements)
    raise ActionController::BadRequest, "elements must be an array" unless elements.is_a?(Array)

    elements.map do |element|
      element.respond_to?(:to_unsafe_h) ? element.to_unsafe_h : element
    end
  end

  def whiteboard_payload
    return @chat_session.whiteboard&.current_state || Whiteboard.default_state if chat_whiteboard_request?

    {
      scene_json: { elements: @repository_whiteboard.elements },
      version: @repository_whiteboard.version
    }
  end

  def update_chat_whiteboard
    elements = whiteboard_elements
    expected_version = params.fetch(:expected_version).to_i

    whiteboard = nil
    state = nil
    status = :ok

    @chat_session.with_lock do
      whiteboard = @chat_session.whiteboard || @chat_session.create_whiteboard!

      if expected_version == whiteboard.version
        whiteboard.replace_elements!(elements)
      else
        status = :conflict
      end

      state = whiteboard.current_state
    end

    render json: state, status: status
  end

  def update_repository_whiteboard
    expected_version = params.require(:expected_version).to_i

    unless @repository_whiteboard.apply_elements!(params.fetch(:elements, []), expected_version: expected_version)
      @repository_whiteboard.reload
      render json: whiteboard_payload, status: :conflict
      return
    end

    render json: whiteboard_payload
  end
end
