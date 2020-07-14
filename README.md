#  PTP Webcam DAL Plugin

Large sensor digital still cameras can provide an exceptionally good image for video conferencing, compared to most built-in web cameras.

This is a plugin to make compatible digital cameras available as webcams in video calls, for example in Zoom or Skype on macOS. It also allows control of camera settings from the computer to adjust exposure parameters and focus.

The project consists of a CoreMediaIO DAL plugin, and a preview app to test functionality.

## Supported Cameras over USB

### Tested

#### Nikon D800 

- needs to be in Photography LiveView mode for exposure preview to be available
- LiveView timeout can be set to infinity via  `CUSTOM SETTINGS MENU -> c Timers/AE Lock -> c4 Monitor off delay -> Live view` 

#### Nikon D3400
- exposure preview not available
 
### Untested
  
The following cameras have support in the code, but have not been confirmed to actually work. If you have one of these cameras, and it does or does not work, please file an issue making a note of how it behaves, so that it can be added here.
  
  - Nikon D90
  - Nikon D300, Nikon D300S, Nikon D500
  - Nikon D3200, Nikon D3300, Nikon D3500
  - Nikon D5000, Nikon D5100, Nikon D5200, Nikon D5300, Nikon D5500, Nikon D5600
  - Nikon D7000, Nikon D7100, Nikon D7200, Nikon D7500
  
  - Nikon Df
  - Nikon D3, Nikon D3S, Nikon D3X, Nikon D4, Nikon D4S, Nikon D5, Nikon D6
  - Nikon D600, Nikon D610
  - Nikon D700, Nikon D750, Nikon D780
  - Nikon D800E, Nikon D810, Nikon D810A, Nikon D850
  
  - Nikon Z50
  
  - Nikon Z6, Nikon Z7
  
Note: some cameras support larger LiveView image sizes, but it is not possible to select that at this time.
 
Many other cameras can in theory be made to work, but are not yet supported.
 
### Not usable because of hardware limitations
 - Nikon D40, D60, D80, D200 do not support tethered live view.
 
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
```
The following additional helpers might be named differently in different Skype versions.
```
codesign --remove-signature Skype\ Helper\ \(GPU\).app
codesign --remove-signature Skype\ Helper\ \(Plugin\).app
codesign --remove-signature Skype\ Helper\ \(Renderer\).app
```
## License

The full license is available in `LICENSE.md` at the same location as this readme.

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


## Acknowledgements

Thanks to Marty Swartz for being the first to help testing additional cameras.

This work would not have been possible without other open-source work:
https://github.com/johnboiles/coremediaio-dal-minimal-example
https://github.com/lvsti/CoreMediaIO-DAL-Example
https://github.com/gphoto/libgphoto2
http://libptp.sourceforge.net
