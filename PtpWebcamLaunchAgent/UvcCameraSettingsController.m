//
//  UvcCameraSettingsController.m
//  PtpWebcamLaunchAgent
//
//  Created by Dömötör Gulyás on 24.01.2021.
//  Copyright © 2021 InRobCo. All rights reserved.
//

#import "UvcCameraSettingsController.h"

#import "UvcCamera.h"
#import "RepresentedSlider.h"

#import <AppKit/AppKit.h>
#import <AVKit/AVKit.h>

@implementation UvcCameraSettingsController
{
	NSMenuItem* statusItem;
	
	
	NSMutableDictionary<id, NSMenuItem*>* menuItemSettingsMap;
}

- (instancetype) initWithCamera: (UvcCamera*) camera delegate: (id <UvcCameraSettingsControllerDelegate>) delegate
{
	if (!(self = [super init]))
		return nil;
	
	self.delegate = delegate;
	self.camera = camera;
	camera.delegate = self;
	
	menuItemSettingsMap = [NSMutableDictionary dictionary];
	
	// build the status item
	[self rebuildStatusItem];
		
	return self;
}


- (void) createStatusItem
{
	if (!statusItem)
	{
		NSString* name = self.camera.device.localizedName;
		assert(name);
		statusItem = [[NSMenuItem alloc] initWithTitle: [NSString stringWithFormat: @"%@ @0x%08X", name, self.camera.locationId] action: NULL keyEquivalent: @""];
		
		[self.delegate showCameraStatusItem: statusItem];
	}
}



- (NSNumber*) valueForSetting: (id) setting fromData: (NSData*) data
{
	if ([setting isEqual: @"exposureTimeAbsolute"])
	{
		uint32_t time = 0;
		[data getBytes: &time range: NSMakeRange(0, sizeof(time))];
		return @(time*1.0e-4);
	}
	else
	{
		return [self.camera rawValueForSetting: setting fromData: data];
	}
}

- (NSString*) uiValueForSetting: (id) setting fromData: (NSData*) data
{
	return [self uiValueForSetting: setting fromRawValue: [self.camera rawValueForSetting: setting fromData: data]];
}

- (NSString*) uiValueForSetting: (id) setting fromRawValue: (NSNumber*) rawNumber
{
	if ([setting isEqual: @"exposureTimeAbsolute"])
	{
		NSInteger time = rawNumber.integerValue;
		return [NSString stringWithFormat: @"%.4f s", time*1.0e-4];
	}
	if ([setting isEqual: @"gamma"])
	{
		NSInteger gamma = rawNumber.integerValue;
		return [NSString stringWithFormat: @"%.2f", gamma*1.0e-2];
	}
	else if (UvcCamera.settingsValueNames[setting] && UvcCamera.settingsValueNames[setting][rawNumber])
	{
		return UvcCamera.settingsValueNames[setting][rawNumber];
	}
	else
		return [NSString stringWithFormat: @"%li", rawNumber.integerValue];
}

- (NSMenuItem*) menuItemForSetting: (id) setting
{
	NSString* name = [UvcCamera settingsNames][setting];
	
	
	NSDictionary* settingInfo = self.camera.settingsInfos[setting];
	
	uint8_t flags = [settingInfo[@"flags"] unsignedCharValue];
	
	bool readable = 0 != (flags & 0x01);
	bool writable = 0 != (flags & 0x02);
	bool disabledBecauseAuto = 0 != (flags & 0x04);
	bool disabledBecauseState = 0 != (flags & 0x20);
	
	bool isEnabled = writable && !disabledBecauseAuto && !disabledBecauseState;
	
	NSString* title = name ? name : setting;
	
	if (readable && settingInfo[@"current"])
		title = [NSString stringWithFormat: @"%@ (%@)", title, [self uiValueForSetting: setting fromData: settingInfo[@"current"]]];
	
	NSMenuItem* settingItem = [[NSMenuItem alloc] init];
	[settingItem setTitle: title];
	settingItem.representedObject = setting;
	menuItemSettingsMap[setting] = settingItem;

	if (isEnabled)
	{
		NSMenu* submenu = [[NSMenu alloc] init];
		
		NSNumber* rawCurrentValue = [self.camera rawValueForSetting: settingItem fromData: settingInfo[@"current"]];
		

		bool hasRange = settingInfo[@"min"] && settingInfo[@"max"];
		if (hasRange) {
			NSInteger min = [[self.camera rawValueForSetting: setting fromData: settingInfo[@"min"]] integerValue];
			NSInteger max = [[self.camera rawValueForSetting: setting fromData: settingInfo[@"max"]] integerValue];

			size_t resolution = settingInfo[@"resolution"] ? [[self.camera rawValueForSetting: setting fromData: settingInfo[@"resolution"]] unsignedLongValue] : 1;
			
			size_t num = (max-min)/resolution;
			if (num < 50)
			{
				for (NSInteger i = min; i <= max; i += resolution)
				{
					NSString* valstr = [self uiValueForSetting: setting fromRawValue: @(i)];
					
					NSMenuItem* valueItem = [[NSMenuItem alloc] init];
					valueItem.title = valstr;
					valueItem.representedObject = @{@"setting": setting, @"value" : @(i)};
					valueItem.action =  @selector(changeCameraPropertyAction:);
					valueItem.target = self;

					if (rawCurrentValue.integerValue == i)
					{
						valueItem.state = NSControlStateValueOn;
					}
					
					[submenu addItem: valueItem];
				}
			}
			else
			{
				RepresentedSlider* slider = [[RepresentedSlider alloc] initWithFrame: NSMakeRect(0, 0, 160, 16)];
				slider.minValue = 0.0;
				slider.maxValue = 1.0;
				slider.doubleValue = _mapValueToSlider(min, max, [rawCurrentValue doubleValue]);
				slider.representedObject = setting;
//				slider.tag = propertyId.intValue;
				slider.target = self;
				slider.action = @selector(propertySliderAction:);
				slider.continuous = NO; // only send action when done sliding around to prevent too many PTP calls
				
				NSMenuItem* subItem = [[NSMenuItem alloc] init];
//				subItem.representedObject = setting;
	//			subItem.title =  [NSString stringWithFormat: @"Property Range: %@", property[@"range"]];
				subItem.view = slider;
	//			subItem.enabled = NO;
				[submenu addItem: subItem];

			}
		}
		else if (UvcCamera.settingsValueNames[setting])
		{
			for (NSNumber* val in UvcCamera.settingsValueNames[setting])
			{
				// auto exposure mode has a weird bitmapped validity thing
				if ([@"autoExposureMode" isEqual: setting])
				{
					size_t resolution = settingInfo[@"resolution"] ? [[self.camera rawValueForSetting: setting fromData: settingInfo[@"resolution"]] unsignedLongValue] : 1;

					// skip if value is not in the resolution bitmap
					if (!(val.unsignedCharValue & resolution))
						continue;
				}
				NSString* valstr = [self uiValueForSetting: setting fromRawValue: val];
				
				NSMenuItem* valueItem = [[NSMenuItem alloc] init];
				valueItem.title = valstr;
				valueItem.representedObject = @{@"setting": setting, @"value" : val};
				valueItem.action =  @selector(changeCameraPropertyAction:);
				valueItem.target = self;

				if (rawCurrentValue.integerValue == val.integerValue)
				{
					valueItem.state = NSControlStateValueOn;
				}
				
				[submenu addItem: valueItem];

			}
		}
		
		if (submenu.numberOfItems > 0)
			settingItem.submenu = submenu;
	}
	

	return settingItem;
}

static double _mapValueToSlider(double min, double max, double val)
{
	double u = (val - min)/(max-min);
	// low ratio is simple linear
	if (fabs(max/min) > 10.0)
	{
		return sqrt(u);
	}
	else // if (fabs(max/min) <= 10.0)
	{
		return u;
	}
}

static double _mapSliderToValue(double min, double max, double slider)
{
	if (fabs(max/min) > 10.0)
	{
		double u = slider*slider;
		return u*(max-min) + min;
	}
	else // if (fabs(max/min) <= 10.0)
	{
		double u = slider;
		return u*(max-min) + min;
	}
}

- (void) updateSettingValue: (id) setting
{
	NSMenuItem* settingItem = menuItemSettingsMap[setting];
	
	if (settingItem)
	{
		NSString* name = [UvcCamera settingsNames][setting];
		
		NSDictionary* settingInfo = self.camera.settingsInfos[setting];
				
		NSString* title = name ? name : setting;
		
		if (settingInfo[@"current"])
			title = [NSString stringWithFormat: @"%@ (%@)", title, [self uiValueForSetting: setting fromData: settingInfo[@"current"]]];

		settingItem.title = title;
	}
}

- (IBAction) propertySliderAction: (RepresentedSlider*)sender
{
	id setting = sender.representedObject;
	
	NSDictionary* settingInfo = self.camera.settingsInfos[setting];

	NSInteger min = [[self.camera rawValueForSetting: setting fromData: settingInfo[@"min"]] integerValue];
	NSInteger max = [[self.camera rawValueForSetting: setting fromData: settingInfo[@"max"]] integerValue];

	size_t res = settingInfo[@"resolution"] ? [[self.camera rawValueForSetting: setting fromData: settingInfo[@"resolution"]] unsignedLongValue] : 1;

	NSInteger ival = _mapSliderToValue(min, max, sender.doubleValue);
	// make sure we're only hitting allowed values (multiples of res)
	NSInteger value =((ival - min)/res)*res + min;
	
	[self setSetting: setting toRawValue: @(value)];
	[self.camera readSettingInfo: setting];

	[self updateSettingValue: setting];

}

- (IBAction) changeCameraPropertyAction: (NSMenuItem*)sender
{
	// set, then query setting for updated value
	
	NSDictionary* info = sender.representedObject;
	id setting = info[@"setting"];

	[self setSetting: setting toRawValue: info[@"value"]];
	[self.camera readSettingInfo: setting];
	
	if ([setting isEqual: @"whiteBalanceTemperatureAuto"])
		[self.camera readSettingInfo: @"whiteBalanceTemperature"];
	else if ([setting isEqual: @"whiteBalanceComponentAuto"])
		[self.camera readSettingInfo: @"whiteBalanceComponent"];
	else if ([setting isEqual: @"contrastAuto"])
		[self.camera readSettingInfo: @"contrast"];
	else if ([setting isEqual: @"hueAuto"])
		[self.camera readSettingInfo: @"hue"];
	else if ([setting isEqual: @"focusAuto"])
		[self.camera readSettingInfo: @"focusAbsolute"];
	else if ([setting isEqual: @"autoExposureMode"])
	{
		[self.camera readSettingInfo: @"exposureTimeAbsolute"];
		[self.camera readSettingInfo: @"apertureAbsolute"];
	}

	
	[self rebuildStatusItem];
}

- (void) setSetting: (id) setting toRawValue: (NSNumber*) rawValue
{
	NSLog(@"UI Setting %@ to %@", setting, rawValue);
	[self.camera setCurrentValue: rawValue forSetting: setting];
}

- (void) rebuildStatusItem
{
	[self createStatusItem];
	
	NSMenu* menu = [[NSMenu alloc] init];
	
	{
		NSMenuItem* item = [[NSMenuItem alloc] init];
		item.title =  @"Generate Camera Report…";
		item.target = self;
		item.action =  @selector(generateCameraReport:);
		[menu addItem: item];
		[menu addItem: [NSMenuItem separatorItem]];
	}
	
	NSMutableArray* sortedSettings = self.camera.supportedSettings.allKeys.mutableCopy;
	[sortedSettings sortUsingComparator: ^NSComparisonResult(id  _Nonnull obj1, id  _Nonnull obj2) {
		return [obj1 compare: obj2];
	}];

	for (NSString* setting in sortedSettings)
	{
		// skip unsupported settings
		if (![self.camera.supportedSettings[setting] boolValue])
			continue;
		

		NSMenuItem* settingItem = [self menuItemForSetting: setting];
		if (settingItem)
			[menu addItem: settingItem];
	}
	
	

	statusItem.submenu = menu;
}

- (void) removeStatusItem
{
	if (statusItem)
		[self.delegate removeCameraStatusItem: statusItem];

}

- (void) cameraRemoved:(UvcCamera *)camera
{
	[self removeStatusItem];
}

- (void) dealloc
{
	[self removeStatusItem];
}


@end
