class TagsController < ApplicationController
  before_action :load_tag, only: %i[ update destroy ]

  def index
    @tags = Current.user.tags.ordered.includes(:jobs)
    @tag = Current.user.tags.new(color: "gray")
  end

  def create
    @tag = Current.user.tags.new(tag_params)
    if @tag.save
      redirect_to tags_path, notice: "Tag created."
    else
      @tags = Current.user.tags.ordered.includes(:jobs)
      render :index, status: :unprocessable_entity
    end
  end

  def update
    if @tag.update(tag_params)
      redirect_to tags_path, notice: "Tag updated."
    else
      @tags = Current.user.tags.ordered.includes(:jobs)
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    @tag.destroy!
    redirect_to tags_path, notice: "Tag deleted."
  end

  private

  def load_tag
    @tag = Current.user.tags.find(params[:id])
  end

  def tag_params
    params.require(:tag).permit(:name, :color)
  end
end
