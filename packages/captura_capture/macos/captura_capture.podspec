Pod::Spec.new do |s|
  s.name             = 'captura_capture'
  s.version          = '0.1.0'
  s.summary          = 'Captura AVFoundation de baixa latência para o CapturaPlay.'
  s.description      = <<-DESC
Captura vídeo e áudio de um dispositivo UVC (como um Cam Link) com prévia nativa.
                       DESC
  s.homepage         = 'https://capturaplay.local'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'CapturaPlay' => 'dev@capturaplay.local' }
  s.source           = { :path => '.' }
  s.source_files = 'captura_capture/Sources/captura_capture/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '14.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
  s.frameworks = 'AVFoundation', 'CoreMedia', 'CoreVideo', 'Cocoa'
end
