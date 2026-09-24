#!/usr/bin/env ruby
require 'xcodeproj'

root = File.expand_path('..', __dir__)
project_path = File.join(root, 'ios', 'App', 'App.xcodeproj')
abort("Missing Xcode project: #{project_path}") unless File.exist?(project_path)

team_id = ENV.fetch('APPLE_TEAM_ID', '').strip
profile_name = ENV.fetch('PROFILE_NAME', '').strip
abort('APPLE_TEAM_ID is required') if team_id.empty?
abort('PROFILE_NAME is required') if profile_name.empty?

project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'App' } || project.targets.first
abort('Could not find the App target') unless target

target.build_configurations.each do |config|
  settings = config.build_settings
  settings['DEVELOPMENT_TEAM'] = team_id
  settings['CODE_SIGN_STYLE'] = 'Manual'
  settings['CODE_SIGN_IDENTITY'] = 'Apple Distribution'
  settings['PROVISIONING_PROFILE_SPECIFIER'] = profile_name
end

project.save
puts "Applied manual signing to App target only."
puts "Team: #{team_id}"
puts "Profile: #{profile_name}"
