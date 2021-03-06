module Markdownable
  extend ActiveSupport::Concern
  include ActiveModel::Dirty

  included do
    before_save :cache_rendered_markdown
  end

  def cache_rendered_markdown
    changed_attribute_names_to_save.select { |c| c.end_with?("markdown") }.each do |col_markdown|
      col = col_markdown.remove("_markdown")
      public_send("#{col}=", Kramdown::Document.new(
        public_send(col_markdown).to_s, { coderay_line_numbers: nil, syntax_highlighter: 'rouge' }).to_html)
    end
  end
end
