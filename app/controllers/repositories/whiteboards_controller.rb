class Repositories::WhiteboardsController < ApplicationController
  before_action :load_repository
  before_action :load_chat_session

  def show
    render json: current_state
  end

  def update
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

  private

  def load_repository
    @repository = Current.user.repositories.find(params[:repository_id])
  end

  def load_chat_session
    @chat_session = @repository.chat_sessions.find(params[:chat_id])
  end

  def current_state
    @chat_session.whiteboard&.current_state || Whiteboard.default_state
  end

  def whiteboard_elements
    elements = params.fetch(:elements)
    raise ActionController::BadRequest, "elements must be an array" unless elements.is_a?(Array)

    elements.map do |element|
      element.respond_to?(:to_unsafe_h) ? element.to_unsafe_h : element
    end
  end
end
