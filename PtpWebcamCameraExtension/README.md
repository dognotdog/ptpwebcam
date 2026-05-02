#  PTPWebcamCameraExtension notes
- for development porposes, we need to
  `systemextensionsctl developer on`
  but for that to work we need to disable SIP as of MacOS 13: reboot into system recovery mode, and CLI do
  `csrutil disable`

- when trying to install into /Applications, don't use `DST_ROOT=/` build setting, but `INSTALL_ROOT=/` instead, lest Xcode 15 confuse itself. 

Links for getting things updated
 - https://developer.apple.com/documentation/servicemanagement/updating_helper_executables_from_earlier_versions_of_macos
 - https://developer.apple.com/documentation/servicemanagement
 
