#!/usr/bin/env ruby
# Add the screenshot-only SceneDelegate to the generated App target sources.
require 'xcodeproj'
root = File.expand_path('../..', __dir__)
project_path = File.join(root, 'ios/App/App.xcodeproj')
project = Xcodeproj::Project.open(project_path)
app = project.targets.find { |target| target.name == 'App' }
abort('Missing native App target') unless app
group = project.main_group.find_subpath('App', true)
ref = group.files.find { |entry| entry.path == 'SceneDelegate.swift' || entry.display_name == 'SceneDelegate.swift' }
ref ||= group.new_file('SceneDelegate.swift')
unless app.source_build_phase.files_references.include?(ref)
  app.source_build_phase.add_file_reference(ref, true)
end
project.save
puts 'SceneDelegate.swift added to app sources for iOS 27 screenshot runner.'
