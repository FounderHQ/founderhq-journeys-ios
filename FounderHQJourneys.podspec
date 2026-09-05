Pod::Spec.new do |s|
  s.name = 'FounderHQJourneys'
  s.version = '0.1.1'
  s.summary = 'FounderHQ Journeys SDK for iOS'
  s.homepage = 'https://github.com/FounderHQ/founderhq-journeys-ios'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.author = { 'FounderHQ' => 'tech@getfounderhq.com' }
  s.source = { :git => 'https://github.com/FounderHQ/founderhq-journeys-ios.git', :tag => "v#{s.version}" }
  s.source_files = 'Sources/FounderHQJourneys/**/*.swift'
  s.ios.deployment_target = '15.0'
  s.swift_version = '5.0'
end
