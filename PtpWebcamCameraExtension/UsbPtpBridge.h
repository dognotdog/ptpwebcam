// UsbPtpBridge.h
// ObjC wrapper that uses the old IOUSBLib (IOUSBInterfaceUserClientV3) instead of
// IOUSBHost (IOUSBHostInterfaceUserClient).  IOUSBLib does NOT enforce
// IOServiceDEXTEntitlements, so it can be opened from UID 262 with only the
// com.apple.security.device.usb sandbox entitlement.

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

NS_ASSUME_NONNULL_BEGIN

// ─── PtpUsbPipe ────────────────────────────────────────────────────────────
// Represents one endpoint pipe on a PTP USB interface.
// Lifetime: must not outlive the PtpUsbInterface that created it.

@interface PtpUsbPipe : NSObject

@property (readonly) uint8_t pipeIndex;    // 1-based IOUSBLib pipe index
@property (readonly) uint8_t bmAttributes; // 0x02 = bulk, 0x03 = interrupt
@property (readonly) uint8_t address;      // e.g. 0x81 (IN) or 0x01 (OUT)

/// Clear a stalled endpoint (USB ClearFeature ENDPOINT_HALT + device-side clear).
/// Call this after opening a fresh interface if the previous owner may have
/// left endpoints in a stalled state.
- (BOOL)clearStallWithError:(NSError **)error;

/// Synchronous bulk send.  Returns YES on success.
- (BOOL)sendData:(NSMutableData *)data
 bytesTransferred:(nullable NSUInteger *)btx
          timeout:(NSTimeInterval)timeout
            error:(NSError **)error;

/// Synchronous bulk/interrupt receive into a pre-allocated buffer.
/// On success *rxd holds the number of bytes actually received.
- (BOOL)receiveInto:(NSMutableData *)buffer
      bytesReceived:(nullable NSUInteger *)rxd
            timeout:(NSTimeInterval)timeout
              error:(NSError **)error;

@end


// ─── PtpUsbInterface ───────────────────────────────────────────────────────
// An opened PTP USB interface via IOUSBLib.
// Opens using kIOUSBInterfaceUserClientTypeID (IOUSBInterfaceUserClientV3),
// which does NOT require com.apple.developer.driverkit.transport.usb.

@interface PtpUsbInterface : NSObject

/// Opens the USB interface at the given IOKit service.
/// Returns nil + *error on failure (e.g. kIOReturnExclusiveAccess if another
/// process holds the interface, or kIOReturnNotPrivileged if the kernel denies).
- (nullable instancetype)initWithService:(io_service_t)service
                                   error:(NSError **)error;

/// All pipes discovered on this interface (enumerated immediately after open).
@property (readonly) NSArray<PtpUsbPipe *> *pipes;

/// Closes the interface and releases the exclusive lock.
- (void)close;

@end


// ─── UsbPtpBridge (static helpers) ────────────────────────────────────────

@interface UsbPtpBridge : NSObject

/// Returns a CFMutableDictionary matching IOUSBHostInterface services with
/// bInterfaceClass=6 (Still Imaging / PTP) and bInterfaceSubClass=1.
/// Caller receives +1 retain; use __bridge_transfer or CFRelease.
+ (nullable CFMutableDictionaryRef)ptpMatchingDictionary CF_RETURNS_RETAINED;

/// Reads VID, PID, and product name from the IOKit service (or its parent device).
+ (void)readVendorID:(nullable uint16_t *)outVid
           productID:(nullable uint16_t *)outPid
         productName:(NSString * _Nullable * _Nullable)outName
         fromService:(io_service_t)service;

/// Performs a USB device re-enumeration (soft reset) via the parent device of the
/// given USB interface service.  After this call, the interface service becomes
/// invalid; the camera re-appears as a new IOKit service after ~3–5 seconds.
/// Returns YES if the reset was initiated (actual re-enumeration is async).
+ (BOOL)resetDevice:(io_service_t)interfaceService error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
