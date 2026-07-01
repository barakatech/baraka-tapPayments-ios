Pod::Spec.new do |s|
  s.name             = 'TapPayments-Card-iOS'
  s.version          = '1.0.13'
  s.summary          = 'From the shelf card processing library provided by Tap Payments'
  s.homepage         = 'https://github.com/barakatech/baraka-tapPayments-ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'AlexDBaraka' => 'alexandre@getbaraka.com' }
  s.source           = { :git => 'https://github.com/barakatech/baraka-tapPayments-ios.git', :tag => "v#{s.version}" }
  s.ios.deployment_target = '13.0'
  s.swift_version = '5.0'
  s.source_files = 'Sources/Card-iOS/Logic/**/*.swift'
  s.resources = "Sources/Card-iOS/Resources/**/*.{json,xib,pdf,png,gif,storyboard,xcassets,xcdatamodeld,lproj}"
  s.dependency'SwiftyRSA'
  s.dependency'SharedDataModels-iOS'
  s.dependency'TapCardScannerWebWrapper-iOS'
  s.dependency'TapFontKit-iOS'
  
  
end
