#!/usr/bin/env ruby
# Script to add macOS source files to the MedicalFactChecker Xcode project
# Run this from the ios/MedicalFactChecker directory

require 'xcodeproj'
require 'pathname'

# Open the project
project_path = 'MedicalFactChecker.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Get the main target
target = project.targets.find { |t| t.name == 'MedicalFactChecker' }
unless target
  puts "Error: Could not find MedicalFactChecker target"
  exit 1
end

# Find the Sources group
sources_group = project.main_group.find_subpath('Sources', false)
unless sources_group
  puts "Error: Could not find Sources group"
  exit 1
end

# Remove the old folder reference if it exists
sources_group.children.each do |child|
  if child.is_a?(Xcodeproj::Project::Object::PBXFileReference) && child.path == 'macOS'
    child.remove_from_project
    puts "Removed old macOS folder reference"
  end
end

# Remove the existing macOS group if it exists (to clean up old file references)
existing_macos = sources_group.find_subpath('macOS', false)
if existing_macos
  # Remove all file references from build phase
  existing_macos.recursive_children.each do |child|
    if child.is_a?(Xcodeproj::Project::Object::PBXFileReference)
      target.source_build_phase.files.each do |build_file|
        if build_file.file_ref == child
          target.source_build_phase.files.delete(build_file)
        end
      end
    end
  end
  existing_macos.remove_from_project
  puts "Removed old macOS group and its file references"
end

# Create macOS group structure
macos_group = sources_group.find_subpath('macOS', false) || sources_group.new_group('macOS', 'macOS')

# Create subgroups
app_group = macos_group.find_subpath('App', false) || macos_group.new_group('App', 'App')
views_group = macos_group.find_subpath('Views', false) || macos_group.new_group('Views', 'Views')
views_factcheck_group = views_group.find_subpath('FactCheck', false) || views_group.new_group('FactCheck', 'FactCheck')
views_history_group = views_group.find_subpath('History', false) || views_group.new_group('History', 'History')
views_report_group = views_group.find_subpath('Report', false) || views_group.new_group('Report', 'Report')
views_settings_group = views_group.find_subpath('Settings', false) || views_group.new_group('Settings', 'Settings')
views_help_group = views_group.find_subpath('Help', false) || views_group.new_group('Help', 'Help')
views_onboarding_group = views_group.find_subpath('Onboarding', false) || views_group.new_group('Onboarding', 'Onboarding')
views_components_group = views_group.find_subpath('Components', false) || views_group.new_group('Components', 'Components')

# Helper function to add a file to a group and target
def add_file_to_group(group, file_path, target)
  file_ref = group.new_file(file_path)
  target.source_build_phase.add_file_reference(file_ref)
  puts "Added: #{file_path}"
end

# Add macOS source files
puts "\nAdding macOS source files..."

# App files
add_file_to_group(app_group, 'MedicalFactCheckerMacApp.swift', target)
add_file_to_group(app_group, 'MacContentView.swift', target)

# MacConstants.swift and MacUtilities.swift (in macOS root)
add_file_to_group(macos_group, 'MacConstants.swift', target)
add_file_to_group(macos_group, 'MacUtilities.swift', target)

# FactCheck views
['MacFactCheckView.swift', 'MacFetchMoreView.swift', 'MacFullTextTab.swift',
 'MacFullTextViewer.swift', 'MacScoredDocumentsView.swift',
 'MacSearchOptionsToolbar.swift', 'MacSearchProgressView.swift'].each do |file|
  add_file_to_group(views_factcheck_group, file, target)
end

# History views
add_file_to_group(views_history_group, 'MacHistoryView.swift', target)

# Report views
['MacReportView.swift', 'MacPrintableReportView.swift'].each do |file|
  add_file_to_group(views_report_group, file, target)
end

# Settings views
add_file_to_group(views_settings_group, 'MacSettingsView.swift', target)

# Help views
add_file_to_group(views_help_group, 'MacHelpViews.swift', target)

# Onboarding views
add_file_to_group(views_onboarding_group, 'MacOnboardingView.swift', target)

# Components
['MacDocumentSourceBadge.swift', 'MacFullTextSourceBadge.swift', 'MacErrorQueueView.swift',
 'MacSortingControlsView.swift', 'MacProcessingProgressView.swift'].each do |file|
  add_file_to_group(views_components_group, file, target)
end

# Save the project
project.save
puts "\nProject saved successfully!"
puts "macOS files have been added to the MedicalFactChecker target."
puts "\nNext steps:"
puts "1. Open the project in Xcode"
puts "2. Select the MedicalFactChecker target"
puts "3. Choose 'My Mac' from the destination dropdown to build for macOS"
