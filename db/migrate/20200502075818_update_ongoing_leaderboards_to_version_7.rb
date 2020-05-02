class UpdateOngoingLeaderboardsToVersion7 < ActiveRecord::Migration[5.2]
  def change
    update_view :ongoing_leaderboards, version: 7, revert_to_version: 6
  end
end
