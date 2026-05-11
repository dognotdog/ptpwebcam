// UsbPtpBridge.m
// IOUSBLib-based USB transport.  Uses IOUSBInterfaceUserClientV3 (the old stack)
// which does NOT enforce IOServiceDEXTEntitlements — avoiding kIOReturnNotPrivileged
// that IOUSBHostInterfaceUserClient (new stack) returns from UID 262.
//
// Sandbox note: com.apple.security.device.usb allows IOUSBInterfaceUserClientV3
// in cmioextension.sb, so no additional entitlement is needed.

#import "UsbPtpBridge.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOUSBHost/IOUSBHost.h>   // only used for ptpMatchingDictionary

// ─── IOUSBLib type alias ───────────────────────────────────────────────────
// IOUSBInterfaceInterface300 has WritePipeTO / ReadPipeTO / GetNumEndpoints /
// GetPipeProperties — everything we need.
typedef IOUSBInterfaceInterface300 USBIfaceImpl;


// ─── PtpUsbPipe ────────────────────────────────────────────────────────────

@implementation PtpUsbPipe {
    USBIfaceImpl **_iface;   // raw ptr — NOT retained; owned by PtpUsbInterface
    uint8_t       _pipeIndex;
    uint8_t       _bmAttributes;
    uint8_t       _address;
}

@synthesize pipeIndex    = _pipeIndex;
@synthesize bmAttributes = _bmAttributes;
@synthesize address      = _address;

- (instancetype)initWithInterface:(USBIfaceImpl **)iface
                        pipeIndex:(uint8_t)idx
                     bmAttributes:(uint8_t)attrs
                          address:(uint8_t)addr
{
    if (!(self = [super init])) return nil;
    _iface       = iface;
    _pipeIndex   = idx;
    _bmAttributes = attrs;
    _address     = addr;
    return self;
}

- (BOOL)clearStallWithError:(NSError **)error
{
    // ClearPipeStallBothEnds sends USB CLEAR_FEATURE(ENDPOINT_HALT) to the device
    // AND resets the host-side data-toggle.  This is what we need after killing
    // ptpcamerad mid-transfer: the plain ClearPipeStall only clears the host side
    // and never talks to the camera.
    IOReturn kr = (*_iface)->ClearPipeStallBothEnds(_iface, _pipeIndex);
    if (kr != kIOReturnSuccess && error) {
        *error = [NSError errorWithDomain:@"IOUSBErrorDomain"
                                     code:kr
                                 userInfo:@{NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:@"ClearPipeStallBothEnds failed 0x%08x", kr]}];
    }
    return kr == kIOReturnSuccess;
}

- (BOOL)sendData:(NSMutableData *)data
 bytesTransferred:(NSUInteger *)btx
          timeout:(NSTimeInterval)timeout
            error:(NSError **)error
{
    uint32_t ms   = (uint32_t)(timeout * 1000.0);
    uint32_t size = (uint32_t)data.length;
    IOReturn kr = (*_iface)->WritePipeTO(_iface,
                                          _pipeIndex,
                                          data.mutableBytes,
                                          size,
                                          0,    // noDataTimeout
                                          ms);  // completionTimeout
    if (btx) *btx = (kr == kIOReturnSuccess) ? (NSUInteger)size : 0;
    if (kr != kIOReturnSuccess && error) {
        *error = [NSError errorWithDomain:@"IOUSBErrorDomain"
                                     code:kr
                                 userInfo:@{NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:@"WritePipeTO failed 0x%08x", kr]}];
    }
    return kr == kIOReturnSuccess;
}

- (BOOL)receiveInto:(NSMutableData *)buffer
      bytesReceived:(NSUInteger *)rxd
            timeout:(NSTimeInterval)timeout
              error:(NSError **)error
{
    uint32_t ms   = (uint32_t)(timeout * 1000.0);
    uint32_t size = (uint32_t)buffer.length;
    IOReturn kr = (*_iface)->ReadPipeTO(_iface,
                                         _pipeIndex,
                                         buffer.mutableBytes,
                                         &size,
                                         0,    // noDataTimeout
                                         ms);  // completionTimeout
    // On failure (e.g. timeout), IOUSBLib leaves *size at the input value rather
    // than zeroing it.  Only report the received byte count on success.
    if (rxd) *rxd = (kr == kIOReturnSuccess) ? (NSUInteger)size : 0;
    if (kr != kIOReturnSuccess && error) {
        *error = [NSError errorWithDomain:@"IOUSBErrorDomain"
                                     code:kr
                                 userInfo:@{NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:@"ReadPipeTO failed 0x%08x", kr]}];
    }
    return kr == kIOReturnSuccess;
}

@end


// ─── PtpUsbInterface ───────────────────────────────────────────────────────

@implementation PtpUsbInterface {
    USBIfaceImpl       **_iface;
    NSArray<PtpUsbPipe *> *_pipes;
}

@synthesize pipes = _pipes;

- (nullable instancetype)initWithService:(io_service_t)service
                                   error:(NSError **)error
{
    if (!(self = [super init])) return nil;

    // 1. Create IOCFPlugin for the USB interface service.
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service,
        kIOUSBInterfaceUserClientTypeID,   // → opens IOUSBInterfaceUserClientV3
        kIOCFPlugInInterfaceID,
        &plugin,
        &score);

    if (kr != KERN_SUCCESS || !plugin) {
        if (error) {
            *error = [NSError errorWithDomain:@"IOUSBErrorDomain"
                                         code:kr
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:
                                             @"IOCreatePlugInInterfaceForService failed 0x%08x", kr]}];
        }
        return nil;
    }

    // 2. QI for IOUSBInterfaceInterface300.
    USBIfaceImpl **iface = NULL;
    CFUUIDBytes ifaceUUID = CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300);
    HRESULT hr = (*plugin)->QueryInterface(
        plugin,
        ifaceUUID,
        (LPVOID *)&iface);
    (*plugin)->Release(plugin);

    if (hr || !iface) {
        if (error) {
            *error = [NSError errorWithDomain:@"IOUSBErrorDomain"
                                         code:(IOReturn)hr
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"QueryInterface for IOUSBInterfaceInterfaceID300 failed"}];
        }
        return nil;
    }

    // 3. Open (takes exclusive ownership; may fail with kIOReturnExclusiveAccess
    //    if ptpcamerad is running, or kIOReturnNotPrivileged if entitlements wrong).
    IOReturn openResult = (*iface)->USBInterfaceOpen(iface);
    if (openResult != kIOReturnSuccess) {
        (*iface)->Release(iface);
        if (error) {
            *error = [NSError errorWithDomain:@"IOUSBErrorDomain"
                                         code:openResult
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:
                                             @"USBInterfaceOpen failed 0x%08x", openResult]}];
        }
        return nil;
    }

    _iface = iface;

    // 3b. Set alternate interface setting 0 (required to activate endpoints).
    //     PTP cameras have a single alt setting (0); without this call,
    //     WritePipeTO / ReadPipeTO can return kIOUSBNotSent1Err.
    IOReturn altResult = (*iface)->SetAlternateInterface(iface, 0);
    if (altResult != kIOReturnSuccess) {
        // Non-fatal — some cameras don't implement alt-setting selection.
        // Log but continue; pipes may still work.
        NSLog(@"UsbPtpBridge: SetAlternateInterface(0) returned 0x%08x (non-fatal)", altResult);
    }

    // 4. Enumerate pipes (endpoints).
    uint8_t pipeCount = 0;
    (*iface)->GetNumEndpoints(iface, &pipeCount);

    NSMutableArray<PtpUsbPipe *> *pipes = [NSMutableArray arrayWithCapacity:pipeCount];
    for (uint8_t i = 1; i <= pipeCount; i++) {
        uint8_t  direction    = 0;
        uint8_t  number       = 0;
        uint8_t  transferType = 0;
        uint8_t  interval     = 0;
        uint16_t maxPacket    = 0;
        IOReturn pipeKr = (*iface)->GetPipeProperties(
            iface, i,
            &direction, &number, &transferType, &maxPacket, &interval);
        if (pipeKr != kIOReturnSuccess) continue;

        // Reconstruct the USB endpoint address and bmAttributes.
        // direction: kUSBOut=0, kUSBIn=1
        uint8_t addr   = ((direction == kUSBIn) ? 0x80 : 0x00) | (number & 0x7F);
        uint8_t bmAttr = transferType; // kUSBBulk=2, kUSBInterrupt=3

        PtpUsbPipe *pipe = [[PtpUsbPipe alloc] initWithInterface:iface
                                                       pipeIndex:i
                                                    bmAttributes:bmAttr
                                                         address:addr];
        [pipes addObject:pipe];
    }
    _pipes = [pipes copy];

    return self;
}

- (void)close
{
    if (_iface) {
        (*_iface)->USBInterfaceClose(_iface);
        (*_iface)->Release(_iface);
        _iface = NULL;
        _pipes = @[];
    }
}

- (void)dealloc { [self close]; }

@end


// ─── UsbPtpBridge (static helpers) ────────────────────────────────────────

@implementation UsbPtpBridge

+ (nullable CFMutableDictionaryRef)ptpMatchingDictionary
{
    // Use IOUSBHostInterface matching dict — we match services by class, not by
    // which user client we'll open.  The service node is the same for both
    // IOUSBLib and IOUSBHost.
    return [IOUSBHostInterface
        createMatchingDictionaryWithVendorID:nil
                                   productID:nil
                                   bcdDevice:nil
                             interfaceNumber:nil
                          configurationValue:nil
                              interfaceClass:@6
                           interfaceSubclass:@1
                           interfaceProtocol:nil
                                       speed:nil
                              productIDArray:nil];
}

+ (void)readVendorID:(uint16_t *)outVid
           productID:(uint16_t *)outPid
         productName:(NSString **)outName
        serialNumber:(NSString **)outSerial
         fromService:(io_service_t)service
{
    CFTypeRef (^prop)(NSString *) = ^CFTypeRef(NSString *key) {
        CFTypeRef v = IORegistryEntryCreateCFProperty(
            service, (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
        if (v) return v;
        io_registry_entry_t parent = 0;
        if (IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS) {
            v = IORegistryEntryCreateCFProperty(
                parent, (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
            IOObjectRelease(parent);
        }
        return v;
    };

    if (outVid) {
        CFTypeRef v = prop(@"idVendor");
        *outVid = v ? (uint16_t)[(__bridge NSNumber *)v unsignedShortValue] : 0;
        if (v) CFRelease(v);
    }
    if (outPid) {
        CFTypeRef v = prop(@"idProduct");
        *outPid = v ? (uint16_t)[(__bridge NSNumber *)v unsignedShortValue] : 0;
        if (v) CFRelease(v);
    }
    if (outName) {
        CFTypeRef v = prop(@"USB Product Name");
        *outName = v ? (__bridge_transfer NSString *)v : @"PTP Camera";
    }
    if (outSerial) {
        CFTypeRef v = prop(@"USB Serial Number");
        *outSerial = v ? (__bridge_transfer NSString *)v : @"";
    }
}

+ (BOOL)resetDevice:(io_service_t)interfaceService error:(NSError **)error
{
    // 1. Walk up to the parent IOUSBDevice service.
    io_service_t deviceService = IO_OBJECT_NULL;
    kern_return_t kr = IORegistryEntryGetParentEntry(
        interfaceService, kIOServicePlane, &deviceService);
    if (kr != KERN_SUCCESS || deviceService == IO_OBJECT_NULL) {
        if (error) {
            *error = [NSError errorWithDomain:@"IOUSBErrorDomain"
                                         code:kr
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"resetDevice: could not get parent device service"}];
        }
        return NO;
    }

    // 2. Create IOCFPlugin for the USB device (not interface) service.
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kr = IOCreatePlugInInterfaceForService(
        deviceService,
        kIOUSBDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugin,
        &score);
    IOObjectRelease(deviceService);

    if (kr != KERN_SUCCESS || !plugin) {
        if (error) {
            *error = [NSError errorWithDomain:@"IOUSBErrorDomain"
                                         code:kr
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:
                                             @"resetDevice: IOCreatePlugInInterfaceForService failed 0x%08x", kr]}];
        }
        return NO;
    }

    // 3. QI for IOUSBDeviceInterface300.
    IOUSBDeviceInterface300 **devIface = NULL;
    CFUUIDBytes devUUID = CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID300);
    HRESULT hr = (*plugin)->QueryInterface(plugin, devUUID, (LPVOID *)&devIface);
    (*plugin)->Release(plugin);

    if (hr || !devIface) {
        if (error) {
            *error = [NSError errorWithDomain:@"IOUSBErrorDomain"
                                         code:(IOReturn)hr
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"resetDevice: QueryInterface for IOUSBDeviceInterfaceID300 failed"}];
        }
        return NO;
    }

    // 4. Open the device.
    IOReturn openResult = (*devIface)->USBDeviceOpen(devIface);
    if (openResult != kIOReturnSuccess && openResult != kIOReturnExclusiveAccess) {
        (*devIface)->Release(devIface);
        if (error) {
            *error = [NSError errorWithDomain:@"IOUSBErrorDomain"
                                         code:openResult
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:
                                             @"resetDevice: USBDeviceOpen failed 0x%08x", openResult]}];
        }
        return NO;
    }

    // 5. Re-enumerate (soft reset). Causes the camera to disconnect and re-attach.
    //    options=0 → normal re-enumeration. The interface service becomes invalid after this.
    IOReturn resetResult = (*devIface)->USBDeviceReEnumerate(devIface, 0);
    (*devIface)->USBDeviceClose(devIface);
    (*devIface)->Release(devIface);

    if (resetResult != kIOReturnSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:@"IOUSBErrorDomain"
                                         code:resetResult
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:
                                             @"resetDevice: USBDeviceReEnumerate failed 0x%08x", resetResult]}];
        }
        return NO;
    }
    return YES;
}

@end
