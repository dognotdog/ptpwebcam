//
//  PtpWebcamPtpDevice.m
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 06.06.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamPtpDevice.h"
#import "PtpWebcamPtpStream.h"
#import "PtpWebcamAlerts.h"
#import "PtpWebcamPtp.h"


@interface PtpWebcamPtpDevice ()
{
	uint32_t transactionId;
	NSStatusItem* statusItem;
	NSMenuItem* autofocusMenuItem;
	BOOL isPropertyExplorerEnabled;
	BOOL triggerReportGenerationWhenPropertiesComplete;
	NSMutableDictionary* propertyMenuItemLookupTable; // used for changing values shown in property menu items without rebuilding whole menu
}
@end

@implementation PtpWebcamPtpDevice


- (instancetype) initWithCamera: (PtpCamera*) camera pluginInterface: (_Nonnull CMIOHardwarePlugInRef) pluginInterface
{
	if (!(self = [super initWithPluginInterface: pluginInterface]))
		return nil;
		
	self.camera = camera;
	camera.delegate = self;
		
	self.name = camera.model;
	self.manufacturer = camera.make;
	self.elementNumberName = @"1";
	self.elementCategoryName = @"DSLR Webcam";
	self.deviceUid = camera.cameraId;
	self.modelUid = [NSString stringWithFormat: @"ptp-webcam-plugin-model-%@", camera.model];

	isPropertyExplorerEnabled = [[NSProcessInfo processInfo].environment[@"PTPWebcamPropertyExplorerEnabled"] isEqualToString: @"YES"];
	propertyMenuItemLookupTable = [NSMutableDictionary dictionary];

	// camera has been ready for use at this point
	[self queryAllCameraProperties];
	
	// build the status item
//	[self rebuildStatusItem];
	
	return self;
}

- (PtpWebcamPtpStream*) ptpStream
{
	return (id)self.stream;
}


// MARK: PTP Camera Delegate

- (void) cameraDidBecomeReadyForUse: (PtpCamera*) camera
{
	dispatch_async(dispatch_get_main_queue(), ^{
//		[self rebuildStatusItem];
	});
}

- (void) cameraDidBecomeReadyForLiveViewStreaming: (PtpCamera *) camera
{
	[self.ptpStream cameraDidBecomeReadyForLiveViewStreaming];
}

- (void) cameraLiveViewStreamDidBecomeInterrupted: (PtpCamera *) camera
{
	[self.ptpStream cameraLiveViewStreamDidBecomeInterrupted];
}


- (void) cameraFailedToStartLiveView: (PtpCamera*) camera;
{
	[self.ptpStream cameraFailedToStartLiveView];
}

- (void) receivedLiveViewJpegImage:(NSData *)jpegData withInfo:(NSDictionary *)info fromCamera:(PtpCamera *)camera
{
	[self.ptpStream receivedLiveViewJpegImageData: jpegData withInfo: info];
}

- (void) receivedCameraProperty:(NSDictionary *)propertyInfo oldProperty: (NSDictionary*) oldInfo withId:(NSNumber *)propertyId fromCamera:(PtpCamera *)camera
{
	dispatch_async(dispatch_get_main_queue(), ^{
		NSMenuItem* item = self->propertyMenuItemLookupTable[propertyId];
		
		bool descriptionChanged = ![oldInfo isEqual: propertyInfo];
		bool valueChanged = ![oldInfo[@"value"] isEqual: propertyInfo[@"value"]];

		// rebuild menus if this is a newly received UI item
		if (!item && [self.allUiPropertyIds containsObject: propertyId])
			[self rebuildStatusItem];
		else
		{
			if (descriptionChanged)
			{
				NSString* title = [self formatPropertyMenuItemTitleWithValue: propertyInfo[@"value"] defaultValue: propertyInfo[@"defaultValue"] propertyId: propertyId];
				item.title = title;
				
				// need to rebuild the values submenu if rw changed or value changed
				if (![oldInfo[@"rw"] isEqual: propertyInfo[@"rw"]] || valueChanged)
				{
					if ([propertyInfo[@"rw"] boolValue])
					{
						NSMenu* subMenu = [self buildSubMenuForPropertyInfo: propertyInfo withId: propertyId interactive: YES];
						item.submenu = subMenu;
					}
					else
					{
						item.submenu = nil;
					}
				}
			}
		}
		
		switch(propertyId.intValue)
		{
			case PTP_PROP_EXPOSUREPM:
				if (valueChanged)
				{
					// when exposure program mode is changed, availability of iso/shutter/aperture setting might have changed
					if ([self.camera isPtpPropertySupported: PTP_PROP_NIKON_SHUTTERSPEED])
						[self.camera ptpGetPropertyDescription: PTP_PROP_NIKON_SHUTTERSPEED];
					if ([self.camera isPtpPropertySupported: PTP_PROP_FNUM])
						[self.camera ptpGetPropertyDescription: PTP_PROP_FNUM];
					if ([self.camera isPtpPropertySupported: PTP_PROP_EXPOSUREISO])
						[self.camera ptpGetPropertyDescription: PTP_PROP_EXPOSUREISO];
				}
				break;
			case PTP_PROP_NIKON_LV_AFMODE:
				if (valueChanged)
					[self checkAutofocusAvailability];
				break;
		}
	});
	
	[self checkCameraReportTrigger];
}

- (void) checkCameraReportTrigger
{
	// check if we have received all properties
	if (triggerReportGenerationWhenPropertiesComplete)
	{
		NSSet* supportedProperties = [NSSet setWithArray: self.camera.ptpDeviceInfo[@"properties"]];
		NSSet* receivedProperties = [NSSet setWithArray: self.camera.ptpPropertyInfos.allKeys];
		if ([supportedProperties isSubsetOfSet: receivedProperties])
		{
			@synchronized (self) {
				triggerReportGenerationWhenPropertiesComplete = NO;
			}
			[self copyCameraReportToClipboard];
		}
	}

}

- (void) cameraWasRemoved:(PtpCamera *)camera
{
	[self unplugDevice];
}


- (void) unplugDevice
{
	[self.stream unplugDevice];

	[self removeStatusItem];

	[self deleteCmioDevice];
	
}

// MARK: User Interface

- (NSSet*) allUiPropertyIds
{
	NSMutableSet* properties = [NSMutableSet setWithArray: self.camera.uiPtpProperties];

	for (id parentId in self.camera.uiPtpSubProperties)
	{
		NSDictionary* values = self.camera.uiPtpSubProperties[parentId];
		for (id value in values)
		{
			NSArray* subPropertyIds = values[value];
			[properties addObjectsFromArray: subPropertyIds];
		}
	}
	return properties;
}

- (void) queryAllCameraProperties
{
	// if property explorer is enabled, query all properties, else only query properties that are supposed to show up in the UI
	if (isPropertyExplorerEnabled)
	{
		for (id propertyId in self.camera.ptpDeviceInfo[@"properties"])
		{
			[self.camera ptpGetPropertyDescription: [propertyId unsignedIntValue]];
		}
	}
	else
	{
		for (id propertyId in self.allUiPropertyIds)
		{
			if ([self.camera.ptpDeviceInfo[@"properties"] containsObject: propertyId])
				[self.camera ptpGetPropertyDescription: [propertyId unsignedIntValue]];
		}
	}
}


- (void) createStatusItem
{
	// blacklist some processes from creating status items to weed out the worst offenders
	if (PtpWebcamIsProcessGuiBlacklisted())
		return;
	

	// do not create status item if stream isn't running to avoid duplicates for apps with multiple processes accessing DAL plugins

	if (!statusItem)
		statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength: NSVariableStatusItemLength];

	// The text that will be shown in the menu bar
	statusItem.button.title = self.name;
	
	// we could set an image, but the text somehow makes more sense
//	NSBundle *otherBundle = [NSBundle bundleWithIdentifier: @"net.monkeyinthejungle.ptpwebcamdalplugin"];
//	NSImage *image = [otherBundle imageForResource: @"ptpwebcam-logo-22x22"];
//	statusItem.button.image = image;

	// The image that will be shown in the menu bar, a 16x16 black png works best
//	_statusItem.image = [NSImage imageNamed:@"feedbin-logo"];

	// The highlighted image, use a white version of the normal image
//	_statusItem.alternateImage = [NSImage imageNamed:@"feedbin-logo-alt"];

	// The image gets a blue background when the item is selected
//	statusItem.highlightMode = YES;

}

- (void) removeStatusItem
{
	
	[[NSStatusBar systemStatusBar] removeStatusItem: statusItem];
	statusItem = nil;
	
}

- (NSString*) formatPropertyMenuItemTitleWithValue: (id) value defaultValue: (id) defaultValue propertyId: (NSNumber*) propertyId
{
	NSString* valStr = [self.camera formatPtpPropertyValue: value ofProperty: [propertyId intValue] withDefaultValue: defaultValue];
	return [NSString stringWithFormat: @"%@ (%@)", self.camera.ptpPropertyNames[propertyId], valStr];
}

- (NSString*) formatValueMenuItemTitleWithValue: (id) value defaultValue: (id) defaultValue propertyId: (NSNumber*) propertyId
{
	NSString* valStr = [self.camera formatPtpPropertyValue: value ofProperty: [propertyId intValue] withDefaultValue: defaultValue];
	
	if ([defaultValue isEqual: value])
	{
		valStr = [NSString stringWithFormat: @"%@ (default)", valStr];
	}

	return valStr;
}


- (nullable NSMenu*) buildSubMenuForPropertyInfo: (NSDictionary*) property withId: (NSNumber*) propertyId interactive: (BOOL) isInteractive
{
	NSMenu* submenu = [[NSMenu alloc] init];
	id value = property[@"value"];
	id defaultValue = property[@"defaultValue"];
	if ([property[@"range"] isKindOfClass: [NSArray class]])
	{
		NSArray* values = property[@"range"];
		
		for (id enumVal in values)
		{
			NSString* valStr = [self formatValueMenuItemTitleWithValue: enumVal defaultValue: defaultValue propertyId: propertyId];

			NSMenuItem* valueItem = [[NSMenuItem alloc] init];
			valueItem.title =  valStr;
			if (isInteractive)
			{
				valueItem.target = self;
				valueItem.action =  @selector(changeCameraPropertyAction:);
				valueItem.tag = propertyId.integerValue;
				valueItem.representedObject = enumVal;
				
				NSArray* subProperties = [self.camera.uiPtpSubProperties[propertyId] objectForKey: enumVal];
				if (subProperties)
				{
					NSMenu* subPropertyMenu = [[NSMenu alloc] init];

					for (id subPropertyId in subProperties)
					{
						NSDictionary* subInfo = self.camera.ptpPropertyInfos[subPropertyId];
						if (subInfo[@"range"])
						{
							id subValue = subInfo[@"value"];
							id subDefaultValue = subInfo[@"defaultValue"];
							NSString* subValStr = [self formatPropertyMenuItemTitleWithValue: subValue defaultValue: subDefaultValue propertyId: subPropertyId];
							
							
							NSMenu* subsub = [self buildSubMenuForPropertyInfo: subInfo withId: subPropertyId interactive: isInteractive];
							NSMenuItem* subPropertyItem = [[NSMenuItem alloc] init];
							subPropertyItem.title = subValStr;
							propertyMenuItemLookupTable[subPropertyId] = subPropertyItem;
							subPropertyItem.submenu = subsub;
							[subPropertyMenu addItem: subPropertyItem];
						}

					}
					if (subPropertyMenu.numberOfItems > 0)
						valueItem.submenu = subPropertyMenu;
				}
			}
			
			if ([value isEqual: enumVal])
				valueItem.state = NSControlStateValueOn;
			
			[submenu addItem: valueItem];

		}
	}
	else if (property[@"range"]) // Range is a range (min, max, step)
	{
		NSDictionary* rangeInfo = property[@"range"];
		long long rmin = [rangeInfo[@"min"] longLongValue];
		long long rmax = [rangeInfo[@"max"] longLongValue];
		long long step = [rangeInfo[@"step"] longLongValue];
		size_t count = (rmax-rmin+1)/step;
		if (count <= 30)
		{
			for (long long i = rmin; i <= rmax; i += step)
			{
				NSMenuItem* subItem = [[NSMenuItem alloc] init];
				NSString* valStr = [self formatValueMenuItemTitleWithValue: @(i) defaultValue: defaultValue propertyId: propertyId];
				subItem.title = valStr;
				
				if ([value isEqual: @(i)])
					subItem.state = NSControlStateValueOn;
				
				if (isInteractive)
				{
					subItem.target = self;
					subItem.action =  @selector(changeCameraPropertyAction:);
					subItem.tag = propertyId.integerValue;
					subItem.representedObject = @(i);

				}
				[submenu addItem: subItem];
			}
		}
		else
		{
			// add a slider for a range with more items
			NSSlider* slider = [[NSSlider alloc] initWithFrame: NSMakeRect(0, 0, 160, 16)];
			slider.minValue = rmin;
			slider.maxValue = rmax;
			slider.doubleValue = [value doubleValue];
			slider.tag = propertyId.intValue;
			slider.target = self;
			slider.action = @selector(propertySliderAction:);
			slider.continuous = NO; // only send action when done sliding around to prevent too many PTP calls
			
			NSMenuItem* subItem = [[NSMenuItem alloc] init];
//			subItem.title =  [NSString stringWithFormat: @"Property Range: %@", property[@"range"]];
			subItem.view = slider;
//			subItem.enabled = NO;
			[submenu addItem: subItem];

		}
	}
	else
	{
		NSMenuItem* subItem = [[NSMenuItem alloc] init];
		subItem.title =  @"(Property has available no range)";
		[submenu addItem: subItem];

	}
	if (submenu.numberOfItems > 0)
		return submenu;
	else
		return nil;
}

- (void) checkAutofocusAvailability
{
	NSDictionary* afModeInfo = self.camera.ptpPropertyInfos[@(PTP_PROP_NIKON_LV_AFMODE)];
	if (afModeInfo)
	{
		NSNumber* value = afModeInfo[@"value"];
		switch (value.intValue)
		{
			case 3:
			{
				autofocusMenuItem.title = @"Autofocus unavailable (manual lens)…";
				break;
			}
			case 4:
			{
				autofocusMenuItem.title = @"Autofocus unavailable (manual mode)…";
				break;
			}
			case 0:
			case 1:
			case 2:
			default:
			{
				autofocusMenuItem.enabled = YES;
				autofocusMenuItem.title = @"Autofocus…";
				break;
			}

		}
	}
}

- (void) rebuildStatusItem
{
	if (!statusItem)
	{
		[self createStatusItem];
	}
	
	[propertyMenuItemLookupTable removeAllObjects];
		
	
	NSMenu* menu = [[NSMenu alloc] init];
	NSDictionary* ptpPropertyNames = [self.camera ptpPropertyNames];

	{
		NSString *processName = [[NSProcessInfo processInfo] processName];
		
		NSMenuItem* menuItem = [[NSMenuItem alloc] initWithTitle: [NSString stringWithFormat: @"controlled from \"%@\"", processName] action: NULL keyEquivalent: @""];
		menuItem.target = self;
//		menuItem.action =  @selector(nopAction:);
		[menu addItem: menuItem];

		// add report command
		if (YES)
		{
			NSMenuItem* item = [[NSMenuItem alloc] init];
			item.title =  @"Generate Camera Report…";
			item.target = self;
			item.action =  @selector(generateCameraReport:);
			[menu addItem: item];
		}
		[menu addItem: [NSMenuItem separatorItem]];
	}

	for (id propertyId in self.camera.uiPtpProperties)
	{
		
		if ([propertyId isEqual: @"-"])
		{
			[menu addItem: [NSMenuItem separatorItem]];
		}
		else
		{
			NSString* name = ptpPropertyNames[propertyId];
			if (!name)
				continue;
			NSDictionary* property = self.camera.ptpPropertyInfos[propertyId];

			// if this property hasn't actually been read from camera, don't put it in menu
			if (!property)
				continue;
			
			id value = property[@"value"];
			id defaultValue = property[@"defaultValue"];

			NSMenuItem* propertyItem = [[NSMenuItem alloc] init];
			[propertyItem setTitle: [self formatPropertyMenuItemTitleWithValue: value defaultValue: defaultValue propertyId: propertyId]];
			
			// add submenus for writable items
			if ([property[@"rw"] boolValue])
			{
				if (property[@"range"])
				{
					NSMenu* submenu = [self buildSubMenuForPropertyInfo: property withId: propertyId interactive: YES];
					
					propertyItem.submenu = submenu;
				}
			}
			else
			{
				// assign dummy action so items aren't grayed out
//				propertyItem.target = self;
//				propertyItem.action =  @selector(nopAction:);
			}

			[menu addItem: propertyItem];
			propertyMenuItemLookupTable[propertyId] = propertyItem;
		}
	}
	
	// add autofocus command
	if ([self.camera.ptpDeviceInfo[@"operations"] containsObject: @(PTP_CMD_NIKON_AFDRIVE)])
	{
		[menu addItem: [NSMenuItem separatorItem]];
		autofocusMenuItem = [[NSMenuItem alloc] init];
		autofocusMenuItem.title =  @"Autofocus…";
		autofocusMenuItem.target = self;
		autofocusMenuItem.action =  @selector(autofocusAction:);
		[self checkAutofocusAvailability];
		[menu addItem: autofocusMenuItem];
	}
	
	

	// camera properties
	if (isPropertyExplorerEnabled)
	{
		[menu addItem: [NSMenuItem separatorItem]];
		NSMenuItem* item = [[NSMenuItem alloc] init];
		item.title =  @"PTP Properties";

		NSMenu* submenu = [[NSMenu alloc] init];
		NSArray* properties = self.camera.ptpDeviceInfo[@"properties"];
		
		NSDictionary* propertyNames = self.camera.ptpPropertyNames;
		NSDictionary* propertyInfos = self.camera.ptpPropertyInfos;
		
		for (NSNumber* propertyId in properties)
		{
			
			NSDictionary* propertyInfo = propertyInfos[propertyId];
			
			NSString* name = propertyNames[propertyId];
			NSString* valStr = nil;
			if (name)
				valStr = [NSString stringWithFormat: @"0x%04X %@ = %@ (%@)", propertyId.unsignedIntValue, name, propertyInfo[@"defaultValue"], propertyInfo[@"value"]];
			else
				valStr = [NSString stringWithFormat: @"0x%04X = %@ (%@)", propertyId.unsignedIntValue, propertyInfo[@"defaultValue"], propertyInfo[@"value"]];

			NSMenuItem* subItem = [[NSMenuItem alloc] init];
			subItem.title =  valStr;
			
			NSMenu* subsubmenu = [self buildSubMenuForPropertyInfo: propertyInfo withId: propertyId interactive: NO];
			
			subItem.submenu = subsubmenu;

			if (subsubmenu.numberOfItems > 0)
				[submenu addItem: subItem];

		}
		
		item.submenu = submenu;



		if (submenu.numberOfItems > 0)
			[menu addItem: item];

	}
	// operations
	if (isPropertyExplorerEnabled)
	{
		NSMenuItem* item = [[NSMenuItem alloc] init];
		item.title =  @"PTP Operations";

		NSMenu* submenu = [[NSMenu alloc] init];
		NSArray* operations = self.camera.ptpDeviceInfo[@"operations"];
		NSDictionary* operationNames = self.camera.ptpOperationNames;
		
		for (NSNumber* operationId in operations)
		{
			
			NSString* valStr = [NSString stringWithFormat: @"0x%04X %@", operationId.unsignedIntValue, operationNames[operationId]];

			NSMenuItem* subItem = [[NSMenuItem alloc] init];
			subItem.title =  valStr;
			
			[submenu addItem: subItem];

		}
		
		item.submenu = submenu;



		[menu addItem: item];

	}

	statusItem.menu = menu;

}
- (IBAction) autofocusAction:(NSMenuItem*)sender
{
	if ([self.camera isPtpPropertySupported: PTP_PROP_NIKON_LV_AFMODE])
		[self.camera ptpGetPropertyDescription: PTP_PROP_NIKON_LV_AFMODE];

	if ([self.camera isPtpOperationSupported: PTP_CMD_NIKON_AFDRIVE])
	{
		[self.camera requestSendPtpCommandWithCode: PTP_CMD_NIKON_AFDRIVE];
	}
}

- (IBAction) changeCameraPropertyAction:(NSMenuItem*)sender
{
	uint32_t propertyId = (uint32_t)sender.tag;
	
	[self.camera ptpSetProperty: propertyId toValue: sender.representedObject];

	[self.camera ptpGetPropertyDescription: propertyId];
//	[self.camera ptpQueryKnownDeviceProperties];
}

- (IBAction) propertySliderAction: (NSSlider*) sender
{
	uint32_t propertyId = (uint32_t)sender.tag;
	NSDictionary* propertyInfo = self.camera.ptpPropertyInfos[@(propertyId)];
	
	NSDictionary* rangeInfo = propertyInfo[@"range"];
	
	
	long long rmin = [rangeInfo[@"min"] longLongValue];
//	long long rmax = [rangeInfo[@"max"] longLongValue];
	long long step = [rangeInfo[@"step"] longLongValue];

	long value = rmin + floor((sender.doubleValue - rmin)/step)*step;

	NSString* valStr = [self.camera formatPtpPropertyValue: @(value) ofProperty: propertyId withDefaultValue: propertyInfo[@"defaultValue"]];

	NSMenuItem* item = propertyMenuItemLookupTable[@(propertyId)];
	item.title = [NSString stringWithFormat: @"%@ (%@)", self.camera.ptpPropertyNames[@(propertyId)], valStr];


	[self.camera ptpSetProperty: propertyId toValue: @((long)value)];

//	[self.camera ptpQueryKnownDeviceProperties];
}

- (void) copyCameraReportToClipboard
{
	NSString* report = [self.camera cameraPropertyReport];
	
	NSPasteboardItem* item = [[NSPasteboardItem alloc] init];
	[item setString: report forType: NSPasteboardTypeString];
	
	[[NSPasteboard generalPasteboard] clearContents];
	[[NSPasteboard generalPasteboard] writeObjects: @[item]];
	
	PtpWebcamShowInfoAlert(@"Camera Report Generated", @"The camera report has been copied to the clipboard, you can now paste it anywhere.");
}

- (IBAction) generateCameraReport:(NSMenuItem*)sender
{
	// query all properties
	triggerReportGenerationWhenPropertiesComplete = YES;
	for (id propertyId in self.camera.ptpDeviceInfo[@"properties"])
	{
		[self.camera ptpGetPropertyDescription: [propertyId unsignedIntValue]];
	}

	[self checkCameraReportTrigger];
}



- (IBAction) nopAction:(NSMenuItem*)sender
{
	// do nothing, this only exists so that menu items aren't grayed out
}


@end
