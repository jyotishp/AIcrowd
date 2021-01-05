class SubmissionsController < ApplicationController
  before_action :set_user_by_token, except: [:index, :show]
  before_action :authenticate_participant!, except: [:index, :show]
  before_action :set_submission, only: [:show, :edit, :update]
  before_action :set_challenge
  before_action :set_challenge_rounds, only: [:index, :new, :create, :show]
  before_action :set_vote, only: [:index, :new, :create, :show]
  before_action :set_follow, only: [:index, :new, :create, :show]
  before_action :check_participation_terms, except: [:show, :index, :export]
  before_action :set_s3_direct_post, only: [:new, :new_api, :edit, :create, :update]
  before_action :set_submissions_remaining, except: [:show, :index]
  before_action :set_current_round, only: [:index, :new, :create]
  before_action :set_form_type, only: [:new, :create]
  before_action :handle_code_based_submissions, only: [:create]
  before_action :handle_artifact_based_submissions, only: [:create]

  layout :set_layout
  respond_to :html, :js

  def index
    if params[:baselines] == 'true'
      filter = policy_scope(Submission)
                    .where(
                      challenge_round_id: @current_round&.id,
                      challenge_id:       @challenge.id,
                      baseline:           true)
                    .where.not(participant_id: nil)
      @baselines = true
    else
      @baselines      = false
      @my_submissions = true if params[:my_submissions] == 'true' && current_participant
      if @my_submissions
        filter = policy_scope(Submission)
                      .where(
                        challenge_round_id: @current_round&.id,
                        challenge_id:       @challenge.id,
                        participant_id:     current_participant.id)
        @submissions_remaining = SubmissionsRemainingQuery.new(
          challenge:      @challenge,
          participant_id: current_participant.id).call
      else
        filter = policy_scope(Submission)
                      .where(
                        challenge_round_id: @current_round&.id,
                        challenge_id:       @challenge.id)
                      .freeze_record(current_participant, @current_round&.default_leaderboard)

      end
    end
    if @meta_challenge.present?
      filter = filter.where(meta_challenge_id: @meta_challenge.id)
    end

    if @challenge.meta_challenge
      params[:meta_challenge_id] = @challenge.slug
      filter = policy_scope(Submission)
                      .where(challenge_round_id: @challenge.meta_active_round_ids,
                             meta_challenge_id: @challenge.id)
      filter = filter.where(participant_id: current_participant.id) if @my_submissions
    end
    @search = filter.search(search_params)
    @search.sorts = 'created_at desc' if @search.sorts.empty?
    params[:page] ||= 1
    @submissions  = @search.result.includes(:participant).per_page_kaminari(params[:page]).per(10)
  end

  def filter
    Rails.logger.debug('PARAMS Q')
    Rails.logger.debug(params[:q])
    @search      = policy_scope(Submission).ransack(params[:q])
    @submissions = @search.result
                       .where(challenge_id: @challenge.id)
                       .per_page_kaminari(1).per(10)
    render @submissions
  end

  def show
    @presenter = SubmissionDetailPresenter.new(
      submission:   @submission,
      challenge:    @challenge,
      view_context: view_context
    )

    if @submission.meta['description_markdown'].present?
      @description_markdown = Kramdown::Document.new(@submission.meta['description_markdown'], { coderay_line_numbers: nil }).to_html.html_safe
      if @description_markdown.include?("<p><code>mermaid")
        start_index = @description_markdown.index(">mermaid")
        @description_markdown.remove!("mermaid")
        @description_markdown.insert(start_index, " class='mermaid'")
        @description_markdown = EmojiParser.detokenize(EmojiParser.detokenize(@description_markdown))
        @description_markdown = @description_markdown.html_safe
      end
    end

    render :show
  end

  def new
    @clef_primary_run_disabled          = clef_primary_run_disabled?
    @submissions_remaining, @reset_dttm = SubmissionsRemainingQuery.new(
      challenge:      @challenge,
      participant_id: current_participant.id
    ).call
    @submission = @challenge.submissions.new
    @submission.challenge = @challenge
    @submission.submission_files.build
    authorize @submission
  end

  def create
    session_info = {participant_id: current_participant.id, online_submission: true, submission_received_from: is_api_request? ? "api" : "web"}
    if @meta_challenge.present?
      session_info[:meta_challenge_id] = @meta_challenge.id
    end
    @submission = @challenge.submissions.new(submission_params.merge(session_info))
    @submission.challenge = @challenge
    authorize @submission

    validate_submission_file_presence
    if @submission.errors.none? && @submission.save
      SubmissionGraderJob.perform_later(@submission.id)

      non_exclusive_meta_challenges = ChallengeProblems.where(problem_id: @challenge.id, exclusive: false)
      if non_exclusive_meta_challenges.present?
        challenge = non_exclusive_meta_challenges.first.challenge
        registration = challenge.challenge_participants.where(participant_id: current_participant.id).first
        if registration.present? and registration.registered
          @submission.meta_challenge_id = challenge.id
          @submission.save!
        end
      end

      redirect_or_json(helpers.challenge_submissions_path(@challenge), "Submission accepted", :ok, "Submission accepted", {"submission_id": @submission.id, "created_at": @submission.created_at})
    else
      @submission.submission_files.build
      flash[:error] = @submission.errors.full_messages.to_sentence
      render_or_json :new
    end
  end

  def edit
    authorize @submission
  end

  def update
    authorize @submission
    if @submission.update(submission_params)
      redirect_to @challenge,
                  notice: 'Submission updated.'
    else
      flash[:error] = @submission.errors.full_messages.to_sentence
      render :edit
    end
  end

  def destroy
    submission = Submission.find(params[:id])
    submission.destroy
    redirect_to helpers.challenge_leaderboards_path(@challenge), notice: 'Submission was successfully destroyed.'
  end

  def export
    authorize @challenge, :export?

    @submissions = @challenge.submissions
      .includes(:participant, :challenge_round)
      .where(challenge_round_id: params[:submissions_export_challenge_round_id].to_i)

    downloadable = @challenge.submissions_downloadable || current_participant.admin?
    csv_data = Submissions::CSVExportService.new(submissions: @submissions, downloadable:downloadable).call.value


    send_data csv_data,
              type:     'text/csv',
              filename: "#{@challenge.challenge.to_s.parameterize.underscore}_submissions_export.csv"
  end

  def new_api
    check_participation_terms
    @submissions_remaining, @reset_dttm = SubmissionsRemainingQuery.new(
      challenge:      @challenge,
      participant_id: current_participant.id
    ).call
    if @submissions_remaining < 1
      redirect_or_json(helpers.challenge_submissions_path(@challenge), "Submission limit reached for your account, it will reset at #{@reset_dttm}", :forbidden)
      return
    end
    render json: {message: "Presigned key generated!", data: { fields: @s3_direct_post.fields, url: @s3_direct_post.url }, success: true}, status: :ok
  end

  private

  def set_submission
    @submission = Submission.find(params[:id])
    authorize @submission
  rescue ActiveRecord::RecordNotFound
    flash[:error] = "Submission not found."
    redirect_or_json(root_path, "Submission not found.", :not_found)
  end

  def set_challenge
    @challenge     = Challenge.friendly.find(params[:challenge_id])
    challenge_type = params['ml_challenge_id'].present? ? 'ml_challenge_id' : 'meta_challenge_id'

    if params.has_key?(challenge_type) && params[challenge_type.to_sym] != params[:challenge_id]
      if params['ml_challenge_id'].present?
        @ml_challenge = Challenge.includes(:organizers).friendly.find(params[challenge_type.
          to_sym])
      else
        @meta_challenge = Challenge.includes(:organizers).friendly.find(params[challenge_type.
          to_sym])
      end
    elsif @challenge.meta_challenge || @challenge.ml_challenge
      params[challenge_type.to_sym] = params[:challenge_id]
    end

    if !params.has_key?(challenge_type)
      cps = ChallengeProblems.where(problem_id: @challenge.id)
      cps.each do |cp|
        if cp.exclusive?
          challenge_type_id                = "#{cp.challenge.challenge_type}_id"
          params[challenge_type_id.to_sym] = Challenge.find(cp.challenge_id).slug
          redirect_to helpers.challenge_submissions_path(@challenge) and return
        end
      end
    end
  rescue ActiveRecord::RecordNotFound
    flash[:error] = "Challenge not found."
    redirect_or_json(root_path, "Challenge not found.", :not_found)
  end

  def set_challenge_rounds
    @challenge_rounds = @challenge.challenge_rounds.started
  end

  def set_vote
    @vote = @challenge.votes.where(participant_id: current_participant.id).first if current_participant.present?
  end

  def set_follow
    @follow = @challenge.follows.where(participant_id: current_participant.id).first if current_participant.present?
  end

  def set_current_round
    @current_round = if params[:challenge_round_id].present?
                       @challenge.challenge_rounds.find(params[:challenge_round_id].to_i)
                     else
                       @challenge.active_round || @challenge.challenge_rounds.first
                     end
  end

  def set_form_type
    @form_type = @current_round&.submissions_type || 'artifact'
  end

  def check_participation_terms
    challenge = @challenge
    if @meta_challenge.present?
      challenge = @meta_challenge
    end

    unless policy(challenge).has_accepted_challenge_rules? && policy(challenge).has_accepted_participation_terms?
      terms_accept_page = "#{request.env["HTTP_HOST"]}#{challenge_challenge_rules_path(challenge)}"
      redirect_or_json(challenge_challenge_rules_path(challenge), "Please accept challenge terms before making submission here: #{terms_accept_page}", :unauthorized)
    end
  end

  def grader_logs
    if @challenge.grader_logs
      s3_key       = "grader_logs/#{@challenge.slug}/grader_logs_submission_#{@submission.id}.txt"
      s3           = S3Service.new(s3_key)
      @grader_logs = s3.filestream
    end
    return @grader_logs
  end

  def submission_params
    params
        .require(:submission)
        .permit(
          :ml_challenge_id,
          :meta_challenge_id,
          :challenge_id,
          :participant_id,
          :description,
          :score,
          :score_secondary,
          :grading_status,
          :grading_message,
          :api,
          :grading_status_cd,
          :media_content_type,
          :media_thumbnail,
          :media_large,
          :docker_configuration_id,
          :clef_method_description,
          :clef_retrieval_type,
          :clef_run_type,
          :clef_primary_run,
          :clef_other_info,
          :clef_additional,
          :online_submission,
          :baseline,
          :baseline_comment,
          :submission_link,
          submission_files_attributes: [
            :id,
            :seq,
            :submission_file_s3_key,
            :submission_type,
            :_delete
          ])
  end

  def get_s3_key
    "submission_files/challenge_#{@challenge.id}/#{SecureRandom.uuid}_${filename}"
  end

  def set_s3_direct_post
    @s3_direct_post = S3_BUCKET.presigned_post(key: get_s3_key, success_action_status: '201', acl: 'private')
  end

  def handle_code_based_submissions
    return if params[:submission][:submission_type] != "code" || is_api_request?
    file_location = get_s3_key.gsub("${filename}", "editor_input." + params[:language])
    begin
      S3_BUCKET.object(file_location).put(body: params[:submission][:submission_data])
    rescue Aws::S3::Errors::ServiceError
      redirect_to helpers.challenge_submissions_path(@challenge), notice: 'Submission upload failed, please try again.'
    end

  end

  def handle_artifact_based_submissions
    if is_api_request?
      params[:submission] = {'submission_files_attributes': {} }
      if params[:submission_files].nil?
        redirect_or_json(root_path, "Submission file not sent.", :bad_request)
        return
      end
      params[:submission_files].each_with_index do |file, index|
        params[:submission][:submission_files_attributes][index.to_s] = file
        params[:submission][:submission_files_attributes][index.to_s]['submission_type'] = 'artifact'
      end
    end

    return if params.dig('submission', 'submission_files_attributes', '0', 'submission_type') != 'artifact'
    # TODO: Make this accepted extension list dynamic via evaluations API
    accepted_formats = [".csv", ".ipynb", ".pt", ".json", ".py", ".c", ".cpp"]
    file_path = params[:submission][:submission_files_attributes]["0"][:submission_file_s3_key]

    return if file_path.blank?

    extension = File.extname(file_path)
    if accepted_formats.include?(extension)
      params[:submission][:submission_files_attributes]["0"][:submission_type] = extension.gsub(/^./, "")
    end
  end

  def set_submissions_remaining
    @submissions_remaining = @challenge.submissions_remaining(current_participant.id)
  end

  def notify_admins
    Admins::SubmissionNotificationJob.perform_later(@submission.id)
  end

  def clef_primary_run_disabled?
    return true unless @challenge.organizers.any? { |organizer| organizer.clef? }

    sql = %[
        SELECT 'X'
        FROM submissions s
        WHERE s.challenge_id = #{@challenge.id}
        AND s.participant_id = #{current_participant.id}
        AND ((s.clef_primary_run IS TRUE
              AND s.grading_status_cd = 'graded')
              OR s.grading_status_cd IN ('ready', 'submitted', 'initiated'))
      ]
    res = ActiveRecord::Base.connection.select_values(sql)
    res.any?
  end

  def set_layout
    return 'application'
  end

  def validate_submission_file_presence
    @submission.errors.add(:base, 'Submission file is required.') if @form_type == :artifact && @submission.submission_files.none?
  end

  def redirect_or_json(redirect_path, message, status, notice=nil, data=nil)
    if is_api_request?
      if data.present?
        render json: {message: message, success: status == :ok, data: data}, status: status
      else
        render json: {message: message, success: status == :ok}, status: status
      end
    else
      if notice.present?
        redirect_to redirect_path, notice: notice
      else
        redirect_to redirect_path
      end
    end
  end

  def render_or_json(render)
    if is_api_request?
      status = :ok
      message = 'Something went wrong! :('
      if flash[:error].present?
        status = :error
        message = flash[:error]
      end
      render json: {message: message, success: status == :ok}, status: status
    else
      render render
    end
  end
end
