#  PTP Webcam DAL Plugin

This is a DAL plugin to make PTP-compatible digital cameras available as webcams in video calls.

The project consists of a CoreMediaIO DAL plugin, and a preview app to test functionality.

## License



Copyright (C) 2020 Doemoetoer Gulyas

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.

## Supported Cameras over USB

### Tested
 - Nikon D800
 
 ### Untested
  - Nikon D800E
  - Nikon D810
	- note: D810 supports QVGA LiveView image size, but it is not possible to select that at this time
 
 Many other cameras can in theory be made to work, but are not yet supported.
 
 ## Known Issues
 
 ### Library Validation
 
 macOS applications that have library validation enabled cannot load DAL plugins that have not been signed or signed by another developer. Therefore, some popular video conferencing tools do not work out of the box.
 
 The easiest way to workaround is to remove the signature for the offending applications, but note that this might be affected by security settings on your system, and might require to relax security settings.
 
 #### References
 
 https://stackoverflow.com/a/62456259/4296447
 
 #### Zoom workaround
 
 `codesign --remove-signature /Applications/zoom.us.app`
 
 #### Skype workaround
 
 Skype has several helper apps inside its application bundle that might need code signing disabled.

```
cd /Applications/Skype.app/Contents/Frameworks
codesign --remove-signature Skype\ Helper.app
codesign --remove-signature Skype\ Helper\ \(GPU\).app
codesign --remove-signature Skype\ Helper\ \(Plugin\).app
codesign --remove-signature Skype\ Helper\ \(Renderer\).app
```

## Acknowledgements

This app would not have been possible without previous open-source work:
https://github.com/johnboiles/coremediaio-dal-minimal-example
https://github.com/lvsti/CoreMediaIO-DAL-Example
https://github.com/gphoto/libgphoto2
http://libptp.sourceforge.net
