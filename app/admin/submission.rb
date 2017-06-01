ActiveAdmin.register Submission do
  belongs_to :challenge
  navigation_menu :challenge

  index do
    selectable_column
    column :participant_id
    column :score
    column :score_secondary
    column :grading_status_cd
    column :post_challenge
    column :media_content_type
    column :updated_at
    actions
  end

end
