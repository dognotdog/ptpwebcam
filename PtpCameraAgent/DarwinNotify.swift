import Foundation

// Swift wrappers for notify.h C functions (libSystem).
// Using @_silgen_name avoids the need for a bridging header.

@_silgen_name("notify_post")
@discardableResult
func darwin_notify_post(_ name: UnsafePointer<CChar>) -> UInt32

@_silgen_name("notify_register_check")
@discardableResult
func darwin_notify_register_check(_ name: UnsafePointer<CChar>, _ out_token: UnsafeMutablePointer<Int32>) -> UInt32

@_silgen_name("notify_register_dispatch")
@discardableResult
func darwin_notify_register_dispatch(_ name: UnsafePointer<CChar>, _ out_token: UnsafeMutablePointer<Int32>, _ queue: DispatchQueue, _ handler: @escaping @convention(block) (Int32) -> Void) -> UInt32

@_silgen_name("notify_set_state")
@discardableResult
func darwin_notify_set_state(_ token: Int32, _ state64: UInt64) -> UInt32

@_silgen_name("notify_get_state")
@discardableResult
func darwin_notify_get_state(_ token: Int32, _ state64: UnsafeMutablePointer<UInt64>) -> UInt32
