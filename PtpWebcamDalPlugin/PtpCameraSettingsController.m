//
//  PtpCameraSettingsController.m
//  PTP Webcam
//
//  Created by Dömötör Gulyás on 02.09.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpCameraSettingsController.h"

#import "PtpWebcamAlerts.h"
#import "PtpGridTuneView.h"
#import "PtpWebcamStreamView.h"


@implementation PtpCameraSettingsController
{
	NSMenuItem* statusItem;
	NSMenuItem* autofocusMenuItem;
	BOOL isPropertyExplorerEnabled;
	BOOL triggerReportGenerationWhenPropertiesComplete;
	NSMutableDictionary* propertyMenuItemLookupTable; // used for changing values shown in property menu items without rebuilding whole menu
	
	dispatch_source_t frameTimerSource;
	dispatch_queue_t frameQueue;
	BOOL shouldShowPreview;
	
//	NSString* latestVersionString;
}

- (instancetype) initWithCamera: (PtpCamera*) camera delegate: (nullable id<PtpCameraSettingsControllerDelegate>)delegate
{
	if (!(self = [super init]))
		return nil;
	
	self.delegate = delegate;
	self.camera = camera;
		
	self.name = camera.model;
//	self.manufacturer = camera.make;
//	self.elementNumberName = @"1";
//	self.elementCategoryName = @"DSLR Webcam";
//	self.deviceUid = camera.cameraId;
//	self.modelUid = [NSString stringWithFormat: @"ptp-webcam-plugin-model-%@", camera.model];

	isPropertyExplorerEnabled = [[NSProcessInfo processInfo].environment[@"PTPWebcamPropertyExplorerEnabled"] isEqualToString: @"YES"];
	propertyMenuItemLookupTable = [NSMutableDictionary dictionary];

	// camera has been ready for use at this point
	[self queryAllCameraProperties];
	
	// build the status item
//	[self rebuildStatusItem];
	
	// download release info every time a camera is connected
//	[self downloadReleaseInfo];
	
	return self;
}

- (void) receivedCameraProperty:(NSDictionary *)propertyInfo oldProperty: (NSDictionary*) oldInfo withId:(NSNumber *)propertyId fromCamera:(PtpCamera *)camera
{
	dispatch_async(dispatch_get_main_queue(), ^{
		NSMenuItem* item = self->propertyMenuItemLookupTable[propertyId];
		
		bool descriptionChanged = ![oldInfo isEqual: propertyInfo];
		bool valueChanged = ![oldInfo[@"value"] isEqual: propertyInfo[@"value"]];
		bool incremental = [propertyInfo[@"incremental"] boolValue];

		// rebuild menus if this is a newly received UI item
		if (!item && [self.allUiPropertyIds containsObject: propertyId])
			[self rebuildStatusItem];
		// also rebuild if this prop change changes the UI
		else if (valueChanged && [camera isUiChangingProperty: propertyId])
			[self rebuildStatusItem];
		else
		{
			if (descriptionChanged)
			{
				NSString* title = [self formatPropertyMenuItemTitleWithValue: propertyInfo[@"value"] defaultValue: propertyInfo[@"defaultValue"] propertyId: propertyId];
				item.title = title;
				
				// need to rebuild the values submenu if rw changed or value changed
				// but not on valueChanged if it's an incremental item
				if (![oldInfo[@"rw"] isEqual: propertyInfo[@"rw"]] || (valueChanged && !incremental))
				{
					if ([propertyInfo[@"rw"] boolValue])
					{
						NSMenu* subMenu = [self buildSubMenuForPropertyInfo: propertyInfo withId: propertyId interactive: YES];
						item.submenu = subMenu;
						item.enabled = YES;
					}
					else
					{
						item.enabled = NO;
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
					if ([self.camera isPtpPropertySupported: PTP_PROP_SONY_ISO])
						[self.camera ptpGetPropertyDescription: PTP_PROP_SONY_ISO];
					if ([self.camera isPtpPropertySupported: PTP_PROP_SONY_SHUTTERSPEED])
						[self.camera ptpGetPropertyDescription: PTP_PROP_SONY_SHUTTERSPEED];
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

- (void)cameraDidBecomeReadyForUse:(nonnull PtpCamera *)camera {
	// don't care about this in this class, as this should happen before a settings controller is instantiated
}


- (void)cameraWasRemoved:(nonnull PtpCamera *)camera {
	// we never get this, as it's handled at a higher level
}


- (void) cameraAutofocusCapabilityChanged: (PtpCamera*) camera
{
	[self checkAutofocusAvailability];
}

- (void)cameraDidBecomeReadyForLiveViewStreaming:(nonnull PtpCamera *)camera
{
	if (shouldShowPreview)
	{
		[self startFrameTimer];
	}
}


- (void)cameraFailedToStartLiveView:(nonnull PtpCamera *)camera {
	// don't care about this information in this class
}


- (void)cameraLiveViewStreamDidBecomeInterrupted:(nonnull PtpCamera *)camera {
	// don't care about this information in this class
}

- (void) createPreviewWindowWithSize: (CGSize) size
{
	self.streamPreviewWindow = [[NSWindow alloc] initWithContentRect: CGRectMake(0, 0, size.width, size.height) styleMask: NSWindowStyleMaskBorderless | NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView backing: NSBackingStoreBuffered defer: NO];
	self.streamPreviewWindow.level = NSFloatingWindowLevel;
	NSString* version = [[NSBundle mainBundle] objectForInfoDictionaryKey: @"CFBundleShortVersionString"];
	self.streamPreviewWindow.title = [NSString stringWithFormat: @"PTP Webcam v%@ - %@", version, self.name];
	self.streamPreviewWindow.titlebarAppearsTransparent = YES;
	self.streamPreviewWindow.delegate = self;
	self.streamPreviewWindow.releasedWhenClosed = NO;
	[self.streamPreviewWindow center];
	
	self.streamView = [[PtpWebcamStreamView alloc] initWithFrame: CGRectMake(0, 0, size.width, size.height)];
	self.streamView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
		
	[self.streamPreviewWindow.contentView addSubview: self.streamView];


	
	[self.streamPreviewWindow makeKeyAndOrderFront: self];

}

- (void)receivedLiveViewJpegImage:(nonnull NSData *)jpegData withInfo:(nonnull NSDictionary *)info fromCamera:(nonnull PtpCamera *)camera
{
	NSImage* image = [[NSImage alloc] initWithData: jpegData];
	
	if (!image || !shouldShowPreview)
		return;
	
	dispatch_async(dispatch_get_main_queue(), ^{
		
		if (!self.streamPreviewWindow)
		{
			[self createPreviewWindowWithSize: image.size];
		}
		[self.streamView setImage: image];
	});
}




- (NSSet*) allUiPropertyIds
{
	NSMutableSet* properties = [NSMutableSet setWithArray: self.camera.currentUiPtpProperties];

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
	{
		statusItem = [[NSMenuItem alloc] initWithTitle: self.name action: NULL keyEquivalent: @""];
		[self.delegate showCameraStatusItem: statusItem];
	}

	// The text that will be shown in the menu bar
//	statusItem.button.title = self.name;
	
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
	//	[[NSStatusBar systemStatusBar] removeStatusItem: statusItem];
	[self.delegate removeCameraStatusItem: statusItem];
//	[statusItem.parentItem.menu removeItem: statusItem];
//	statusItem.menu = nil;
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

- (nullable NSDictionary*) matrixInfoForPropertyId: (NSNumber*) propertyId
{
	static NSDictionary* matrixInfos = nil;
	NSDictionary* info = self.camera.ptpPropertyInfos[propertyId];
	
	
	
	NSDictionary* nikonWbTuneInfo = @{
		@"gridSize" : @(13),
	};
	matrixInfos = @{
		@(PTP_PROP_NIKON_WBTUNE_INCADESCENT) : nikonWbTuneInfo,
		@(PTP_PROP_NIKON_WBTUNE_FLOURESCENT) : nikonWbTuneInfo,
		@(PTP_PROP_NIKON_WBTUNE_SUNNY) : nikonWbTuneInfo,
		@(PTP_PROP_NIKON_WBTUNE_FLASH) : nikonWbTuneInfo,
		@(PTP_PROP_NIKON_WBTUNE_CLOUDY) : nikonWbTuneInfo,
		@(PTP_PROP_NIKON_WBTUNE_SHADE) : nikonWbTuneInfo,
		@(PTP_PROP_NIKON_MOVIE_WBTUNE_INCADESCENT) : nikonWbTuneInfo,
		@(PTP_PROP_NIKON_MOVIE_WBTUNE_FLOURESCENT) : nikonWbTuneInfo,
		@(PTP_PROP_NIKON_MOVIE_WBTUNE_SUNNY) : nikonWbTuneInfo,
		@(PTP_PROP_NIKON_MOVIE_WBTUNE_CLOUDY) : nikonWbTuneInfo,
		@(PTP_PROP_NIKON_MOVIE_WBTUNE_SHADE) : nikonWbTuneInfo,
		@(PTP_PROP_NIKON_MOVIE_WBTUNE_COLORTEMP) : nikonWbTuneInfo,
	};
	return matrixInfos[propertyId];
}

- (nullable NSMenu*) buildSubMenuForPropertyInfo: (NSDictionary*) property withId: (NSNumber*) propertyId interactive: (BOOL) isInteractive
{
	NSMenu* submenu = [[NSMenu alloc] init];
	
	id value = property[@"value"];
	id defaultValue = property[@"defaultValue"];
	bool incremental = [property[@"incremental"] boolValue];
	NSDictionary* matrixInfo = [self matrixInfoForPropertyId: propertyId];
	
	if (incremental)
	{
		// add buttons for increment/decrement if it's an incremental setting
		
		NSButton* decButton = [NSButton buttonWithTitle: @"-" target: self action: @selector(propertyDecrementAction:)];
		decButton.tag = propertyId.intValue;
		decButton.frameOrigin = NSMakePoint(8, 0);
		decButton.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

		NSButton* incButton = [NSButton buttonWithTitle: @"+" target: self action: @selector(propertyIncrementAction:)];
		incButton.tag = propertyId.intValue;
		incButton.frameOrigin = NSMakePoint(decButton.frame.origin.x + decButton.frame.size.width + 8, 0);
		incButton.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

		
		NSView* view = [[NSView alloc] initWithFrame: NSMakeRect(0, 0, incButton.frame.origin.x + incButton.frame.size.width + 8, incButton.frame.size.height)];
		view.autoresizesSubviews = YES;
		[view addSubview: decButton];
		[view addSubview: incButton];

		NSMenuItem* incrementItem = [[NSMenuItem alloc] init];
		incrementItem.view = view;
		[submenu addItem: incrementItem];

		[submenu addItem: [NSMenuItem separatorItem]];
	}
	else
	{
		// for non incremental items, add selection submenu listing items or a slider
		int gridSize = [matrixInfo[@"gridSize"] intValue];
		if (([property[@"range"] isKindOfClass: [NSDictionary class]]) && (![property[@"range"][@"min"] isEqual: property[@"range"][@"max"]]) && (gridSize != 0))
		{
			
//			PtpLog(@"matrix property 0x%08X: %@", propertyId.unsignedIntValue, property);
						
			PtpGridTuneView* view = [[PtpGridTuneView alloc] initWithFrame: CGRectMake(0, 0, 1, 1)];
			view.autoresizingMask = NSViewNotSizable;
			view.gridSize = gridSize;
			view.representedProperty = property.mutableCopy;
			view.action = @selector(propertyGridAction:);
			view.target = self;
			view.tag = [propertyId intValue];
			[view updateSize];
			
			NSMenuItem* gridItem = [[NSMenuItem alloc] init];
			gridItem.view = view;
			[submenu addItem: gridItem];


		}
		else if ([property[@"range"] isKindOfClass: [NSArray class]])
		{
			NSArray* values = property[@"range"];
			
			for (id enumVal in values)
			{
				NSString* valStr = [self formatValueMenuItemTitleWithValue: enumVal defaultValue: defaultValue propertyId: propertyId];

				NSMenuItem* valueItem = [[NSMenuItem alloc] init];
				valueItem.title =  valStr;
				if (isInteractive && !incremental)
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
				// add a slider for a range with more items, as long as it's not incremental
				
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

	}

	if (submenu.numberOfItems > 0)
		return submenu;
	else
		return nil;
}

- (int) checkAutofocusAvailability
{
	int afCapability = [self.camera canAutofocus];
	
	switch (afCapability)
	{
		case PTPCAM_AF_MANUAL_LENS:
		{
			autofocusMenuItem.title = @"Autofocus unavailable (manual lens)…";
			break;
		}
		case PTPCAM_AF_MANUAL_MODE:
		{
			autofocusMenuItem.title = @"Autofocus unavailable (manual mode)…";
			break;
		}
		case PTPCAM_AF_AVAILABLE:
		{
			autofocusMenuItem.enabled = YES;
			autofocusMenuItem.title = @"Autofocus…";
			break;
		}
		default:
		{
			autofocusMenuItem.title = @"Autofocus status unknown…";
			break;
		}
	}
	return afCapability;
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
		
//		NSString* version = [[NSBundle mainBundle] objectForInfoDictionaryKey: @"CFBundleShortVersionString"];

//		id title = nil;
//		NSMenuItem* menuItem = [[NSMenuItem alloc] initWithTitle: @"camera" action: NULL keyEquivalent: @""];
//
//		if (latestVersionString && ![version isEqualToString: latestVersionString])
//		{
////			NSFont* font = [NSFont menuFontOfSize: 0];
//
//			title = [NSString stringWithFormat: @"New PTP Webcam version %@ available…", latestVersionString];
//
//			menuItem.image = [NSImage imageNamed: NSImageNameFollowLinkFreestandingTemplate];
////			menuItem.image = [NSImage imageNamed: NSImageNameStatusPartiallyAvailable];
////			menuItem.image = [NSImage imageNamed: NSImageNameRefreshTemplate];
//			menuItem.attributedTitle = [[NSAttributedString alloc] initWithString: title attributes: @{
////				NSFontAttributeName : font,
////				NSForegroundColorAttributeName : NSColor.systemRedColor,
////				NSUnderlineStyleAttributeName : @(1)
//			}];
//		}
//		else
//		{
//			title = [NSString stringWithFormat: @"About PTP Webcam v%@…", version];
//			menuItem.title = title;
//		}
//		menuItem.target = self;
//		menuItem.action =  @selector(aboutAction:);
//		[menu addItem: menuItem];

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

	for (id propertyId in self.camera.currentUiPtpProperties)
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
	
	autofocusMenuItem = [[NSMenuItem alloc] init];
	autofocusMenuItem.title =  @"Autofocus…";
	autofocusMenuItem.target = self;
	autofocusMenuItem.action =  @selector(autofocusAction:);

	// preview
	{
		[menu addItem: [NSMenuItem separatorItem]];
		NSMenuItem* item = [[NSMenuItem alloc] init];
		item.title =  @"Preview Video Stream…";
		item.target = self;
		item.action = @selector(previewAction:);
		[menu addItem: item];
	}

	// add autofocus command
	int afCapability = [self checkAutofocusAvailability];
	if (afCapability != PTPCAM_AF_NONE)
	{
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

	statusItem.submenu = menu;

}

- (IBAction) autofocusAction:(NSMenuItem*)sender
{
	// will attempt to autofocus except for PTPCAM_AF_NONE
	if (PTPCAM_AF_NONE != [self.camera canAutofocus])
		[self.camera performAutofocus];
}

- (IBAction) changeCameraPropertyAction:(NSMenuItem*)sender
{
	uint32_t propertyId = (uint32_t)sender.tag;
	
	[self.camera ptpSetProperty: propertyId toValue: sender.representedObject];

	[self.camera ptpGetPropertyDescription: propertyId];
//	[self.camera ptpQueryKnownDeviceProperties];
}

- (IBAction) propertyDecrementAction: (NSSlider*) sender
{
	uint32_t propertyId = (uint32_t)sender.tag;

	[self.camera ptpIncrementProperty: propertyId by: -1];
}

- (IBAction) propertyIncrementAction: (NSSlider*) sender
{
	uint32_t propertyId = (uint32_t)sender.tag;

	[self.camera ptpIncrementProperty: propertyId by: 1];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			[self.camera ptpGetPropertyDescription: propertyId];
	});
}


- (IBAction) propertySliderAction: (NSSlider*) sender
{
	uint32_t propertyId = (uint32_t)sender.tag;
	NSDictionary* propertyInfo = self.camera.ptpPropertyInfos[@(propertyId)];
	
	NSDictionary* rangeInfo = propertyInfo[@"range"];
	
	
	long long rmin = [rangeInfo[@"min"] longLongValue];
//	long long rmax = [rangeInfo[@"max"] longLongValue];
	long long step = [rangeInfo[@"step"] longLongValue];

	long value = rmin + floor((sender.intValue - rmin)/step)*step;

	NSString* valStr = [self.camera formatPtpPropertyValue: @(value) ofProperty: propertyId withDefaultValue: propertyInfo[@"defaultValue"]];

	NSMenuItem* item = propertyMenuItemLookupTable[@(propertyId)];
	item.title = [NSString stringWithFormat: @"%@ (%@)", self.camera.ptpPropertyNames[@(propertyId)], valStr];

//	PtpLog(@"slider 0x%04X set to %@", propertyId, valStr);

	[self.camera ptpSetProperty: propertyId toValue: @((long)value)];

//	[self.camera ptpQueryKnownDeviceProperties];
}

- (IBAction) propertyGridAction: (PtpGridTuneView*) sender
{
	uint32_t propertyId = (uint32_t)sender.tag;
	NSDictionary* propertyInfo = sender.representedProperty;
	
	NSDictionary* rangeInfo = propertyInfo[@"range"];
	NSInteger gridSize = sender.gridSize;
	
	long value = sender.intValue;

	NSString* valStr = [self.camera formatPtpPropertyValue: @(value) ofProperty: propertyId withDefaultValue: propertyInfo[@"defaultValue"]];

	NSMenuItem* item = propertyMenuItemLookupTable[@(propertyId)];
	item.title = [NSString stringWithFormat: @"%@ (%@)", self.camera.ptpPropertyNames[@(propertyId)], valStr];

//	PtpLog(@"grid 0x%04X set to %@ from %d", propertyId, valStr, sender.intValue);

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
	// copy report even if don't have all properties
	[self copyCameraReportToClipboard];
	// query all properties
	triggerReportGenerationWhenPropertiesComplete = YES;
	for (id propertyId in self.camera.ptpDeviceInfo[@"properties"])
	{
		[self.camera ptpGetPropertyDescription: [propertyId unsignedIntValue]];
	}

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

- (void) startFrameTimer
{
	@synchronized (self) {
		if (!frameTimerSource)
		{
			frameTimerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, frameQueue);
			dispatch_source_set_timer(frameTimerSource, DISPATCH_TIME_NOW, 1.0/30.0*NSEC_PER_SEC, 1u*NSEC_PER_MSEC);

			__weak PtpCameraSettingsController* weakSelf = self;
			dispatch_source_set_event_handler(frameTimerSource, ^{
				[weakSelf.camera requestLiveViewImage];
			});
			dispatch_resume(frameTimerSource);
		}
	}
}
- (void) stopFrameTimer
{
	@synchronized (self) {
		if (frameTimerSource)
		{
			dispatch_source_cancel(frameTimerSource);
			frameTimerSource = nil;
		}
	}
}

- (BOOL) incrementStreamCount
{
	BOOL alreadyInLiveView = NO;
	@synchronized (self) {
		int streamCounter = self.streamCounter;
		if (streamCounter == 0)
		{
			PtpLog(@"starting LiveView...");
			[self.camera startLiveView];
		}
		else if (self.camera.isInLiveView)
		{
			alreadyInLiveView = YES;
		}
			
		self.streamCounter = streamCounter+1;
	}
	
	return alreadyInLiveView;

}
- (void) decrementStreamCount
{
	@synchronized (self) {
		int streamCounter = self.streamCounter;
		if (streamCounter == 1)
		{
			PtpLog(@"stopping LiveView...");
			[self.camera stopLiveView];
		}
		self.streamCounter = MAX(0, streamCounter-1);
	}
}


- (IBAction) previewAction:(NSMenuItem*)sender
{
	shouldShowPreview = YES;

	if (!self.streamPreviewWindow)
	{
		BOOL alreadyInLiveView = [self incrementStreamCount];
		if (alreadyInLiveView)
			[self cameraDidBecomeReadyForLiveViewStreaming: self.camera];

	}
	
	[self.streamPreviewWindow center];
	[self.streamPreviewWindow makeKeyAndOrderFront: self];
	
}

- (void) windowWillClose:(NSNotification *)notification
{
	if (notification.object == self.streamPreviewWindow)
	{
		shouldShowPreview = NO;
		
		[self stopFrameTimer];
		[self decrementStreamCount];
		
		self.streamPreviewWindow = nil;
		self.streamView = nil;
	}
}


- (IBAction) aboutAction:(NSMenuItem*)sender
{
	NSString* aboutLink = [NSString stringWithFormat: @"https://ptpwebcam.org/"];
	
	[[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString: aboutLink]];
}


- (IBAction) nopAction:(NSMenuItem*)sender
{
	// do nothing, this only exists so that menu items aren't grayed out
}

@end
