Pod::Spec.new do |s|
  s.name = 'workspace_flutter'
  s.version = '0.1.0'
  s.summary = 'Read-only security-scoped workspace access.'
  s.description = 'Flutter bridge for read-only directory bookmarks.'
  s.homepage = 'https://github.com/mattsp1290/workspace-dart'
  s.license = { :file => '../LICENSE' }
  s.author = { 'Matt Spurlin' => 'matt.spurlin@datadoghq.com' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
end
