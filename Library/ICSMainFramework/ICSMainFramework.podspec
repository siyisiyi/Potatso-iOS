Pod::Spec.new do |s|
  s.name         = "ICSMainFramework"
  s.version      = "0.0.1"
  s.summary      = "ICSMainFramework"
  s.description  = <<-DESC
                   ICSMainFramework.
                   DESC
  s.homepage     = "http://icodesign.me"
  s.license      = "MIT"
  s.author       = { "iCodesign" => "leimagnet@gmail.com" }
  s.platform     = :ios, "8.0"

  s.source       = { :path => '.' }


  # ――― Source Code ―――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #
  #
  #  CocoaPods is smart about how it includes source code. For source files
  #  giving a folder will include any swift, h, m, mm, c & cpp files.
  #  For header files it will include any header in the folder.
  #  Not including the public_header_files will make all headers public.
  #

  s.source_files  = "ICSMainFramework", "ICSMainFramework/**/*.{h,m,swift}"
  s.exclude_files = "ICSMainFramework/Exclude"
end
