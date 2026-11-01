platform :tvos, '17.5'
use_frameworks!

target 'AIOStreamsTV' do
  pod 'MPVKit', :podspec => 'MPVKit.podspec'
  # The fallback player, picked in the app's menu.
  pod 'TVVLCKit', '~> 3.6'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['TVOS_DEPLOYMENT_TARGET'] = '17.5'
    end
  end
end
