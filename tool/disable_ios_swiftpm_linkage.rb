#!/usr/bin/env ruby
# frozen_string_literal: true

# Flutter's generated SwiftPM package reference is committed so the SwiftPM CI
# checkout can build it. CocoaPods mode must remove that reference before Xcode
# evaluates the project: its FlutterFramework package exists only in a SwiftPM
# generated checkout. This operates on a CI checkout, never the source tree.

project = ARGV.fetch(0) { abort "usage: #{$PROGRAM_NAME} path/to/project.pbxproj" }
contents = File.read(project)

sections = [
  %r{/\* Begin XCLocalSwiftPackageReference section \*/.*?/\* End XCLocalSwiftPackageReference section \*/\n}m,
  %r{/\* Begin XCSwiftPackageProductDependency section \*/.*?/\* End XCSwiftPackageProductDependency section \*/\n}m,
]
sections.each do |section|
  abort "missing expected SwiftPM project section" unless contents.sub!(section, "")
end

[
  "78A318202AECB46A00862997", # package product in Runner frameworks
  "78A3181F2AECB46A00862997", # package product dependency
  "781AD8BC2B33823900A9FFBB", # local generated package reference
  "784666492D4C4C64000A1A5F", # generated FlutterFramework file reference
  "78DABEA22ED26510000E7860", # plugin package file reference
  "78E0A7A72DC9AD7400C4905E", # generated plugin package file reference
].each do |identifier|
  abort "missing expected SwiftPM reference #{identifier}" unless contents.include?(identifier)
  contents.gsub!(/^.*#{identifier}.*\n/, "")
end

abort "SwiftPM linkage remains in CocoaPods project" if contents.include?("FlutterGeneratedPluginSwiftPackage")
File.write(project, contents)
