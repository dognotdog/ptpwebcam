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
	BOOL isPropertyExplorerEnabled;
	NSMutableDictionary* menuItemLookupTable; // used for changing values shown in property menu items without rebuilding whole menu
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
	menuItemLookupTable = [NSMutableDictionary dictionary];

	// camera has been ready for use at this point
	[self queryAllCameraProperties];
	
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
		[self rebuildStatusItem];
	});
}

- (void) cameraDidBecomeReadyForLiveViewStreaming:(PtpCamera *)camera
{
	[self.ptpStream cameraDidBecomeReadyForLiveViewStreaming];
}

- (void) receivedLiveViewJpegImage:(NSData *)jpegData withInfo:(NSDictionary *)info fromCamera:(PtpCamera *)camera
{
	[self.ptpStream receivedLiveViewJpegImageData: jpegData withInfo: info];
}

- (void) receivedCameraProperty:(NSDictionary *)propertyInfo withId:(NSNumber *)propertyId fromCamera:(PtpCamera *)camera
{
	dispatch_async(dispatch_get_main_queue(), ^{
		[self rebuildStatusItem];
	});

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
		for (id propertyId in self.camera.uiPtpProperties)
		{
			if ([self.camera.ptpDeviceInfo[@"properties"] containsObject: propertyId])
				[self.camera ptpGetPropertyDescription: [propertyId unsignedIntValue]];
		}
		
		NSMutableSet* subProperties = [NSMutableSet set];
		for (id parentId in self.camera.uiPtpSubProperties)
		{
			NSDictionary* values = self.camera.uiPtpSubProperties[parentId];
			for (id value in values)
			{
				NSArray* subPropertyIds = values[value];
				[subProperties addObjectsFromArray: subPropertyIds];
			}
			
		}
		for (id propertyId in subProperties)
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

- (NSMenu*) buildSubMenuForPropertyInfo: (NSDictionary*) property withId: (NSNumber*) propertyId interactive: (BOOL) isInteractive
{
	NSMenu* submenu = [[NSMenu alloc] init];
	id value = property[@"value"];
	id defaultValue = property[@"defaultValue"];
	if ([property[@"range"] isKindOfClass: [NSArray class]])
	{
		NSArray* values = property[@"range"];
		
		for (id enumVal in values)
		{
			NSString* valStr = [self.camera formatPtpPropertyValue: enumVal ofProperty: propertyId.intValue withDefaultValue: defaultValue];
			if ([defaultValue isEqual: enumVal])
			{
				valStr = [NSString stringWithFormat: @"%@ (default)", valStr];
			}

			NSMenuItem* subItem = [[NSMenuItem alloc] init];
			subItem.title =  valStr;
			if (isInteractive)
			{
				subItem.target = self;
				subItem.action =  @selector(changeCameraPropertyAction:);
				subItem.tag = propertyId.integerValue;
				subItem.representedObject = enumVal;
				
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
							NSString* subValStr = [self.camera formatPtpPropertyValue: subValue ofProperty: [subPropertyId intValue] withDefaultValue: subDefaultValue];
							
							if ([subDefaultValue isEqual: subValue])
							{
								subValStr = [NSString stringWithFormat: @"%@ (default)", subValStr];
							}
							
							NSMenu* subsub = [self buildSubMenuForPropertyInfo: subInfo withId: subPropertyId interactive: isInteractive];
							NSMenuItem* subsubItem = [[NSMenuItem alloc] init];
							subsubItem.title = [NSString stringWithFormat: @"%@ (%@)", self.camera.ptpPropertyNames[subPropertyId], subValStr];
							menuItemLookupTable[subPropertyId] = subsubItem;
							subsubItem.submenu = subsub;
							[subPropertyMenu addItem: subsubItem];
						}
						
					}
					subItem.submenu = subPropertyMenu;
				}
			}
			
			if ([value isEqual: enumVal])
				subItem.state = NSControlStateValueOn;
			
			[submenu addItem: subItem];

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
				NSString* valStr = [self.camera formatPtpPropertyValue: @(i) ofProperty: propertyId.intValue withDefaultValue: defaultValue];
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
			slider.continuous = YES;
			
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
	return submenu;
}

- (void) rebuildStatusItem
{
	if (!statusItem)
	{
		[self createStatusItem];
	}
	
	[menuItemLookupTable removeAllObjects];
		
	
	NSMenu* menu = [[NSMenu alloc] init];
	NSDictionary* ptpPropertyNames = [self.camera ptpPropertyNames];

//	if (isPropertyExplorerEnabled)
	{
		NSString *processName = [[NSProcessInfo processInfo] processName];
		
		NSMenuItem* menuItem = [[NSMenuItem alloc] initWithTitle: [NSString stringWithFormat: @"controlled from \"%@\"", processName] action: NULL keyEquivalent: @""];
		menuItem.target = self;
		menuItem.action =  @selector(nopAction:);

		[menu addItem: menuItem];
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

			id value = property[@"value"];
			NSString* valueString = [self.camera formatPtpPropertyValue: value ofProperty: [propertyId intValue] withDefaultValue: property[@"defaultValue"]];
			
			NSMenuItem* menuItem = [[NSMenuItem alloc] init];
			[menuItem setTitle: [NSString stringWithFormat: @"%@ (%@)", name, valueString]];
			
			// add submenus for writable items
			if ([property[@"rw"] boolValue])
			{
				if (property[@"range"])
				{
					NSMenu* submenu = [self buildSubMenuForPropertyInfo: property withId: propertyId interactive: YES];
					
					menuItem.submenu = submenu;
				}
			}
			else
			{
				// assign dummy action so items aren't grayed out
				menuItem.target = self;
				menuItem.action =  @selector(nopAction:);
			}

			[menu addItem: menuItem];
			menuItemLookupTable[propertyId] = menuItem;
		}
	}
	
	// add autofocus command
	if ([self.camera.ptpDeviceInfo[@"operations"] containsObject: @(PTP_CMD_NIKON_AFDRIVE)])
	{
		[menu addItem: [NSMenuItem separatorItem]];
		NSMenuItem* item = [[NSMenuItem alloc] init];
		item.title =  @"Autofocus…";
		item.target = self;
		item.action =  @selector(autofocusAction:);
		[menu addItem: item];
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

			[submenu addItem: subItem];

		}
		
		item.submenu = submenu;



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
	[self.camera requestSendPtpCommandWithCode: PTP_CMD_NIKON_AFDRIVE];
}

- (IBAction) changeCameraPropertyAction:(NSMenuItem*)sender
{
	uint32_t propertyId = (uint32_t)sender.tag;
	
	[self.camera ptpSetProperty: propertyId toValue: sender.representedObject];

	[self.camera ptpQueryKnownDeviceProperties];
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

	NSMenuItem* item = menuItemLookupTable[@(propertyId)];
	item.title = [NSString stringWithFormat: @"%@ (%@)", self.camera.ptpPropertyNames[@(propertyId)], valStr];


	[self.camera ptpSetProperty: propertyId toValue: @((long)value)];

//	[self.camera ptpQueryKnownDeviceProperties];
}


- (IBAction) nopAction:(NSMenuItem*)sender
{
	// do nothing, this only exists so that menu items aren't grayed out
}


@end
