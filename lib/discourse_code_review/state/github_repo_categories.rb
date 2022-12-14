# frozen_string_literal: true

module DiscourseCodeReview::State::GithubRepoCategories
  GITHUB_REPO_ID = "GitHub Repo ID"
  GITHUB_REPO_NAME = "GitHub Repo Name"
  GITHUB_ISSUES = "Issues"

  class << self
    def ensure_category(repo_name:, repo_id: nil, issues: false)
      Category.transaction(requires_new: true) do
        category =
          scoped_categories(issues: issues).where(
            id:
              CategoryCustomField
                .select(:category_id)
                .where(name: GITHUB_REPO_NAME, value: repo_name)
          ).first

        if category.present? && category.custom_fields[GITHUB_REPO_ID].blank? && repo_id.present?
          category.custom_fields[GITHUB_REPO_ID] = repo_id
          category.save_custom_fields
        end

        # search for category via repo_id
        if category.blank? && repo_id.present?
          category =
            scoped_categories(issues: issues).where(
              id:
                CategoryCustomField
                  .select(:category_id)
                .where(name: GITHUB_REPO_ID, value: repo_id)
            ).first

          if category.present?
            # update repository name in category custom field
            category.custom_fields[GITHUB_REPO_NAME] = repo_name
            category.save_custom_fields
          else
            # create new category
            short_name = find_category_name(repo_name, repo_id, issues)
            description_key = issues ? "issues_category_description" : "category_description"
            category = Category.new(
              name: short_name,
              user: Discourse.system_user,
              description: I18n.t("discourse_code_review.#{description_key}", repo_name: repo_name)
            )
            parent_category_id = get_parent_category_id(repo_name, repo_id, issues)
            if parent_category_id.present?
              category.parent_category_id = parent_category_id
            end

            category.save!

            if SiteSetting.code_review_default_mute_new_categories
              existing_category_ids = Category.where(id: SiteSetting.default_categories_muted.split("|")).pluck(:id)
              SiteSetting.default_categories_muted = (existing_category_ids << category.id).join("|")
            end

            category.custom_fields[GITHUB_REPO_ID] = repo_id
            category.custom_fields[GITHUB_REPO_NAME] = repo_name
            category.custom_fields[GITHUB_ISSUES] = issues
            category.save_custom_fields
          end
        end

        category
      end
    end

    def each_repo_name(&blk)
      CategoryCustomField
        .where(name: GITHUB_REPO_NAME)
        .pluck(:value)
        .each(&blk)
    end

    def github_repo_category_fields
      CategoryCustomField
        .where(name: GITHUB_REPO_NAME)
        .include(:category)
    end

    def get_repo_name_from_topic(topic)
      topic.category.custom_fields[GITHUB_REPO_NAME]
    end

    def get_parent_category_id(repo_name, repo_id, issues)
      parent_category_id = DiscourseCodeReview::Hooks.apply_parent_category_finder(repo_name, repo_id, issues)

      if !parent_category_id && SiteSetting.code_review_default_parent_category.present?
        parent_category_id = SiteSetting.code_review_default_parent_category.to_i
      end

      parent_category_id
    end

    private

    def find_category_name(repo_name, repo_id, issues)
      name = DiscourseCodeReview::Hooks.apply_category_namer(repo_name, repo_id, issues)
      return name if name.present?

      name = repo_name.split("/", 2).last

      if Category.where(name: name).exists?
        name += SecureRandom.hex
      else
        name
      end
    end

    def scoped_categories(issues: false)
      if issues
        Category.where("id IN (SELECT category_id FROM category_custom_fields WHERE name = '#{GITHUB_ISSUES}' and value::boolean IS TRUE)")
      else
        Category
      end
    end
  end
end
