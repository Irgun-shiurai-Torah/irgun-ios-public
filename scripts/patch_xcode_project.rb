#!/usr/bin/env ruby
require 'xcodeproj'

root = File.expand_path('..', __dir__)
project_path = File.join(root, 'ios', 'App', 'App.xcodeproj')
abort("Missing Xcode project: #{project_path}") unless File.exist?(project_path)

bundle_id = (ENV['BUNDLE_ID'] || 'org.irgunshiuraitorah.app').strip
marketing_version = (ENV['IOS_MARKETING_VERSION'] || '1.0.0').strip
build_number = (ENV['BUILD_NUMBER'] || '1').strip.gsub(/[^0-9]/, '')
build_number = '1' if build_number.empty?
native_product_name = (ENV['IOS_PRODUCT_NAME'] || 'IrgunShiuraiTorah').strip
native_product_name = 'IrgunShiuraiTorah' if native_product_name.empty?
native_module_name = native_product_name.gsub(/[^A-Za-z0-9_]/, '')
native_module_name = 'IrgunShiuraiTorah' if native_module_name.empty?

project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'App' } || project.targets.first
abort('Could not find the App target') unless target

(project.build_configurations + target.build_configurations).each do |config|
  settings = config.build_settings

  # Do NOT directly link Apple's private SwiftUICore framework. V1.2.13 added
  # -weak_framework SwiftUICore, but Xcode 26 correctly rejects third-party
  # products as direct clients. Remove any such flag defensively.
  flags = settings['OTHER_LDFLAGS']
  if flags
    arr = flags.is_a?(Array) ? flags.dup : flags.to_s.split(/\s+/)
    cleaned = []
    i = 0
    while i < arr.length
      if ['-weak_framework', '-framework'].include?(arr[i]) && arr[i + 1] == 'SwiftUICore'
        i += 2
        next
      end
      if arr[i].include?('SwiftUICore')
        i += 1
        next
      end
      cleaned << arr[i]
      i += 1
    end
    settings['OTHER_LDFLAGS'] = cleaned.empty? ? ['$(inherited)'] : cleaned
  end

  if target.build_configurations.include?(config)
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = bundle_id
    # Keep the Capacitor target/scheme named App for tooling compatibility, but
    # use a distinct native product/module/executable name. This prevents the
    # application's Swift module itself from being named simply `App`.
    settings['PRODUCT_NAME'] = native_product_name
    settings['PRODUCT_MODULE_NAME'] = native_module_name
    settings['SWIFT_MODULE_NAME'] = native_module_name
    settings['EXECUTABLE_NAME'] = '$(PRODUCT_NAME)'
    settings['MARKETING_VERSION'] = marketing_version
    settings['CURRENT_PROJECT_VERSION'] = build_number
    settings['CODE_SIGN_ENTITLEMENTS'] = 'App/App.entitlements'
  end
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
end

app_group = project.main_group.children.find do |child|
  child.respond_to?(:display_name) && child.display_name == 'App'
end
app_group ||= project.main_group.find_subpath('App', true)

[
  ['GoogleService-Info.plist', true, false],
  ['App.entitlements', false, false],
  ['IrgunAnalyticsPlugin.swift', false, true],
].each do |filename, add_to_resources, add_to_sources|
  absolute = File.join(root, 'ios', 'App', 'App', filename)
  abort("Missing required iOS file: #{absolute}") unless File.exist?(absolute)
  ref = app_group.files.find { |f| f.path == filename || f.display_name == filename }
  ref ||= app_group.new_file(filename)
  if add_to_resources
    unless target.resources_build_phase.files_references.include?(ref)
      target.resources_build_phase.add_file_reference(ref, true)
    end
  end
  if add_to_sources
    unless target.source_build_phase.files_references.include?(ref)
      target.source_build_phase.add_file_reference(ref, true)
    end
  end
end

attrs = project.root_object.attributes['TargetAttributes'] ||= {}
target_attrs = attrs[target.uuid] ||= {}
system_caps = target_attrs['SystemCapabilities'] ||= {}
system_caps['com.apple.SignInWithApple'] = { 'enabled' => 1 }
system_caps['com.apple.Push'] = { 'enabled' => 1 }
system_caps['com.apple.InAppPurchase'] = { 'enabled' => 1 }
system_caps.delete('com.apple.ApplePay')

project.save
puts "Patched Xcode project for #{bundle_id}, version #{marketing_version} (#{build_number})."
puts "Capacitor target/scheme: App"
puts "Native product/module/executable: #{native_product_name}"
puts "Deployment target: iOS 15.0"
puts "Direct SwiftUICore linker flags: removed / forbidden"
