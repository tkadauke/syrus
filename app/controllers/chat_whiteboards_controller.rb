class ChatWhiteboardsController < ApplicationController
  before_action :load_chat_session

  def show
    whiteboard = @chat_session.whiteboard
    render json: {
      scene_json: { elements: whiteboard&.elements || [] },
      version: whiteboard&.version || 0
    }
  end

  def update
    elements = params.fetch(:elements)
    raise ActionController::BadRequest, "elements must be an array" unless elements.is_a?(Array)

    if elements.size > Whiteboard::MAX_ELEMENTS
      render json: { "error" => Whiteboard.element_limit_message }, status: 422
      return
    end

    expected_version = params.fetch(:expected_version).to_i
    status = :ok

    @chat_session.with_lock do
      @whiteboard = @chat_session.whiteboard || @chat_session.create_whiteboard!
      if expected_version == @whiteboard.version
        @whiteboard.replace_elements!(elements.map { |element| element.respond_to?(:to_unsafe_h) ? element.to_unsafe_h : element })
      else
        status = :conflict
      end
    end

    render json: {
      scene_json: { elements: @whiteboard.elements },
      version: @whiteboard.version
    }, status: status
  end

  private

  def load_chat_session
    @chat_session = Current.user.chat_sessions.find(params[:chat_id])
  end
end
