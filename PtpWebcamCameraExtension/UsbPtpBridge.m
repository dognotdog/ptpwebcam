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
typedef IOUSBDeviceInterface300    USBDeviceImpl;


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
    USBDeviceImpl      **_device;  // parent USB device — kept open to hold the seizure
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

    // 3. Get the parent IOUSBDevice service so we can run two eviction
    //    passes against ptpcamerad before opening our interface:
    //
    //      (a) IOUSBHost's `IOUSBHostObjectInitOptionsDeviceSeize` —
    //          modern API, sends `kUSBHostMessageDeviceIsRequestingClose`
    //          via the newer USB stack. Empirically more reliable than
    //          IOUSBLib's USBDeviceOpenSeize against a sticky ptpcamerad.
    //          We drop the IOUSBHostDevice immediately after init; the
    //          eviction message has already been delivered to the prior
    //          owner.
    //      (b) IOUSBLib's `USBDeviceOpenSeize` — legacy API, fallback
    //          path that runs regardless. Holds the device handle open
    //          to prevent ptpcamerad from re-claiming between our
    //          device-seize and the interface-open below.
    io_service_t deviceService = IO_OBJECT_NULL;
    kern_return_t pkr = IORegistryEntryGetParentEntry(service, kIOServicePlane, &deviceService);

    // Pass (a): IOUSBHost-style seize. No special entitlement needed.
    // Best-effort — failure to construct or seize is non-fatal because
    // the IOUSBLib fallback path below covers the same job.
    if (pkr == KERN_SUCCESS && deviceService != IO_OBJECT_NULL) {
        @autoreleasepool {
            NSError *hostErr = nil;
            IOUSBHostDevice *hostDevice =
                [[IOUSBHostDevice alloc]
                  initWithIOService:deviceService
                            options:IOUSBHostObjectInitOptionsDeviceSeize
                              queue:nil
                              error:&hostErr
                    interestHandler:nil];
            if (hostDevice == nil) {
                // Expected on first attempt if ptpcamerad is the owner —
                // the eviction message has nonetheless been sent. Don't
                // log noisily; the IOUSBLib path below will report any
                // real failure with a clearer error.
            } else {
                // Successful seize. Release immediately; we don't need
                // to keep the IOUSBHost handle open — IOUSBLib will
                // take over from here.
                [hostDevice destroy];
                hostDevice = nil;
            }
        }
        // Give ptpcamerad ~50 ms to process the close message before we
        // try to claim the device with IOUSBLib.
        usleep(50 * 1000);
    }

    // Pass (b): IOUSBLib device-level seize. Re-acquire the parent service
    // reference we may have just released, or re-walk from `service` if
    // the autoreleasepool didn't free it.
    if (pkr != KERN_SUCCESS || deviceService == IO_OBJECT_NULL) {
        pkr = IORegistryEntryGetParentEntry(service, kIOServicePlane, &deviceService);
    } else {
        // deviceService was already retrieved; IORegistryEntryGetParentEntry
        // doesn't add a retain reference we manually balance here — fall
        // through with the existing handle.
    }
    USBDeviceImpl **device = NULL;
    if (pkr == KERN_SUCCESS && deviceService != IO_OBJECT_NULL) {
        IOCFPlugInInterface **devPlugin = NULL;
        SInt32 devScore = 0;
        kern_return_t dpkr = IOCreatePlugInInterfaceForService(
            deviceService,
            kIOUSBDeviceUserClientTypeID,
            kIOCFPlugInInterfaceID,
            &devPlugin,
            &devScore);
        IOObjectRelease(deviceService);
        if (dpkr == KERN_SUCCESS && devPlugin) {
            CFUUIDBytes devUUID = CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID300);
            HRESULT devHr = (*devPlugin)->QueryInterface(devPlugin, devUUID, (LPVOID *)&device);
            (*devPlugin)->Release(devPlugin);
            if (devHr || !device) {
                device = NULL;
            } else {
                IOReturn devOpen = (*device)->USBDeviceOpenSeize(device);
                if (devOpen != kIOReturnSuccess) {
                    (*device)->Release(device);
                    device = NULL;
                    // Don't fail outright — try the interface seize alone as
                    // a fallback. Some bodies (e.g. cameras with no
                    // ptpcamerad claim) don't need device-level eviction.
                }
            }
        }
    }
    _device = device;

    // 4. Now open the interface. USBInterfaceOpenSeize asks the kernel to
    //    have any remaining client release. With the device handle held
    //    above, ptpcamerad has already released its claim and the interface
    //    is free; this open succeeds immediately. If we skipped the device
    //    seize (device == NULL), this is the standard polite request that
    //    sometimes works against fresh-state ptpcamerad and sometimes
    //    returns kIOReturnExclusiveAccess.
    IOReturn openResult = (*iface)->USBInterfaceOpenSeize(iface);
    if (openResult != kIOReturnSuccess) {
        if (_device) {
            (*_device)->USBDeviceClose(_device);
            (*_device)->Release(_device);
            _device = NULL;
        }
        (*iface)->Release(iface);
        if (error) {
            *error = [NSError errorWithDomain:@"IOUSBErrorDomain"
                                         code:openResult
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:
                                             @"USBInterfaceOpenSeize failed 0x%08x", openResult]}];
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

- (BOOL)cancelTransactionID:(uint32_t)txnId
                      error:(NSError **)error
{
    if (!_iface) {
        if (error) *error = [NSError errorWithDomain:@"IOUSBErrorDomain" code:kIOReturnNotOpen
                                            userInfo:@{NSLocalizedDescriptionKey:@"interface not open"}];
        return NO;
    }

    // PTP Cancel Transaction payload: 6 bytes, little-endian.
    //   [0..1] cancellation code = 0x4001
    //   [2..5] transaction ID being cancelled
    uint8_t payload[6];
    payload[0] = 0x01;  payload[1] = 0x40;
    payload[2] = (uint8_t)(txnId      & 0xFF);
    payload[3] = (uint8_t)(txnId >> 8 & 0xFF);
    payload[4] = (uint8_t)(txnId >> 16 & 0xFF);
    payload[5] = (uint8_t)(txnId >> 24 & 0xFF);

    IOUSBDevRequestTO req = {0};
    req.bmRequestType     = 0x21;   // host-to-device, class, interface
    req.bRequest          = 0x64;   // PTP Cancel Request
    req.wValue            = 0;
    req.wIndex            = 0;      // interface number (filled by ControlRequest)
    req.wLength           = sizeof(payload);
    req.pData             = payload;
    req.noDataTimeout     = 500;    // ms
    req.completionTimeout = 1000;   // ms

    IOReturn kr = (*_iface)->ControlRequestTO(_iface, /*pipeRef*/0, &req);
    if (kr != kIOReturnSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:@"IOUSBErrorDomain" code:kr
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"PTP CancelRequest failed 0x%08x", kr]}];
        }
        return NO;
    }
    return YES;
}

- (void)close
{
    if (_iface) {
        (*_iface)->USBInterfaceClose(_iface);
        (*_iface)->Release(_iface);
        _iface = NULL;
        _pipes = @[];
    }
    if (_device) {
        // Release the device-level seizure we took in -initWithService:error:.
        // Close before Release so the kernel drops our exclusive claim and
        // ptpcamerad can re-attach for whatever uses image-capture services
        // need after we hand the camera back.
        (*_device)->USBDeviceClose(_device);
        (*_device)->Release(_device);
        _device = NULL;
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

    // 4. Open the device. Seize variant so we don't deadlock against
    //    ptpcamerad's prior open — see USBInterfaceOpenSeize note above
    //    for rationale (matters for App-Sandbox-compatible builds where
    //    we can't fall back to killing ptpcamerad).
    IOReturn openResult = (*devIface)->USBDeviceOpenSeize(devIface);
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
