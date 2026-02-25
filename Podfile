#
#  Podfile
#  Better Now Playing
#
#  Created by JosephPri
#
target 'Better Now Playing' do
  use_frameworks!
  pod 'PockKit'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['ARCHS'] = '$(ARCHS_STANDARD)'
    end
  end
end