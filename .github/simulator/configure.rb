#!/usr/bin/env ruby
require 'xcodeproj'

root = File.expand_path('../..', __dir__)
path = File.join(root, 'ios/App/App.xcodeproj')
project = Xcodeproj::Project.open(path)
app = project.targets.find { |target| target.name == 'App' }
abort('Missing App target') unless app
group = project.main_group.find_subpath('App', true)
probe = group.new_file('SimulatorProbe.swift')
app.source_build_phase.add_file_reference(probe, true)

tests = project.new_target(:ui_test_bundle, 'SimulatorUITests', :ios, '15.0')
tests.add_dependency(app)
test_group = project.main_group.new_group('SimulatorUITests', 'SimulatorUITests')
file = test_group.new_file('PlaybackUITests.swift')
tests.source_build_phase.add_file_reference(file, true)
tests.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_NAME' => 'SimulatorUITests',
    'PRODUCT_MODULE_NAME' => 'SimulatorUITests',
    'EXECUTABLE_NAME' => '$(PRODUCT_NAME)',
    'WRAPPER_EXTENSION' => 'xctest',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'org.irgunshiuraitorah.app.simulator-tests',
    'SWIFT_VERSION' => '5.0',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'ENABLE_TESTING_SEARCH_PATHS' => 'YES',
    'TEST_TARGET_NAME' => 'App',
    'TARGETED_DEVICE_FAMILY' => '1,2',
    'CODE_SIGNING_ALLOWED' => 'NO',
  })
end
attrs = project.root_object.attributes['TargetAttributes'] ||= {}
attrs[tests.uuid] = { 'TestTargetID' => app.uuid }
project.save

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, tests)
scheme.test_action.build_configuration = 'Debug'
test_env = Xcodeproj::XCScheme::EnvironmentVariables.new
test_env['IST_TEST_EMAIL'] = ENV.fetch('IST_TEST_EMAIL', '')
test_env['IST_TEST_PASSWORD'] = ENV.fetch('IST_TEST_PASSWORD', '')
scheme.test_action.environment_variables = test_env
scheme.test_action.should_use_launch_scheme_args_env = false
scheme.save_as(path, 'SimulatorPlayback', true)
puts 'Created SimulatorPlayback scheme and UI test target.'
