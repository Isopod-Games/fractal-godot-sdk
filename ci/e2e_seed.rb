# Seeds the minimal data the SDK Integration E2E workflow needs:
#   - one Organization, User, Project (with project_id = 1 if possible)
#   - one ApiKey with a fixed, well-known key
#   - one LocalizationLanguage ('es')
#   - two approved Translations for keys 'ui.greeting' and 'ui.farewell'
#
# Idempotent — re-running yields the same row IDs.
#
# Run via:  bin/rails runner sdks/godot/ci/e2e_seed.rb

API_KEY  = "ci-e2e-fixed-api-key"
PROJ_ID  = 1
LOCALE   = "es"

org = Organization.find_or_create_by!(name: "CI E2E Org") do |o|
  o.plan = "studio"
end
# Idempotent for rows created before this org needed error/minidump ingestion —
# error_tracking is gated to Indie/Studio, and the e2e suite asserts /v1/errors
# and /v1/minidumps rows land in ClickHouse.
org.update!(plan: "studio")
user = User.find_or_create_by!(email: "ci@example.com") do |u|
  u.name = "CI Bot"
  u.password = "password123"
end
project = Project.find_or_create_by!(name: "CI E2E Project") do |p|
  p.organization = org
  p.user = user
  p.slug = "ci-e2e-#{SecureRandom.hex(4)}"
end

# Force project_id == PROJ_ID for predictable assertions.
if project.id != PROJ_ID
  ActiveRecord::Base.connection.execute(
    "UPDATE projects SET id = #{PROJ_ID.to_i} WHERE id = #{project.id.to_i}"
  )
  ActiveRecord::Base.connection.execute(
    "ALTER SEQUENCE projects_id_seq RESTART WITH #{(PROJ_ID + 1).to_i}"
  )
  project = Project.find(PROJ_ID)
end

ApiKey.find_or_create_by!(project: project, key: API_KEY) do |k|
  k.active = true
  k.description = "CI integration test key"
end

language = LocalizationLanguage.find_or_create_by!(project: project, code: LOCALE) do |l|
  l.name = "Spanish"
end

[
  [ "ui.greeting", "Hola CI" ],
  [ "ui.farewell", "Adios CI" ]
].each do |key_str, value|
  key = TranslationKey.find_or_create_by!(project: project, key: key_str)
  translation = Translation.find_or_initialize_by(
    translation_key: key,
    localization_language: language,
  )
  translation.value = value
  translation.status = "approved"
  translation.approved_at ||= Time.current
  translation.save!
end

puts "Seeded: project_id=#{project.id} api_key=#{API_KEY} locale=#{LOCALE}"
puts "Translations: " + Translation
  .joins(:translation_key)
  .where(translation_keys: { project_id: project.id }, status: "approved")
  .pluck("translation_keys.key", :value)
  .inspect
