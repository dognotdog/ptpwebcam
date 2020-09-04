//
//  FoundationExtensions.h
//  common
//
//  Created by Dömötör Gulyás on 18.01.12.
//  Copyright (c) 2012-2020 Doemoetoer Gulyas. All rights reserved.
//

#import <Foundation/Foundation.h>

dispatch_source_t dispatch_coalesce_source_create(dispatch_queue_t queue);
void dispatch_coalesce(dispatch_source_t src, double time, void (^block)(void));


@interface NSArray (FoundationExtensions)

- (NSArray*) map: (id (^)(id obj)) block;
- (NSArray*) indexedMap: (id (^)(id obj, NSInteger index)) block;
- (NSArray*) select: (BOOL (^)(id obj)) block;

- (NSArray*) arrayByRemovingObjectsAtIndexes: (NSIndexSet*) indexes;
- (NSArray*) arrayByInsertingObjects: (NSArray*) ary atIndexes: (NSIndexSet*) indexes;
- (NSArray*) arrayByInsertingObject: (id) obj atIndex: (NSUInteger) index;

- (NSArray*) arrayByRemovingObject: (id) obj;
- (NSArray*) arrayByRemovingObjectsInArray: (NSArray*) ary;
- (NSArray*) arrayByRemovingLastObject;

//- (NSArray*) continuousSubarraysWithCommonProperty: (BOOL (^)(id referenceObject, id obj)) block;
- (NSArray*) arraysByDeinterleavingColumns: (NSUInteger) numColumns;
- (NSArray*) arraysBySlicingAfterLimit: (NSUInteger) numLimit;

@end

static inline void* memcpy_ntohs(uint16_t* dst, const void* src, size_t count)
{
	memcpy(dst, src, 2*count);
	for (int i = 0; i < count; ++i)
		dst[i] = ntohs(dst[i]);
	
	return dst;
}

static inline void* memcpy_ntohl(uint32_t* dst, const void* src, size_t count)
{
	memcpy(dst, src, 4*count);
	for (int i = 0; i < count; ++i)
		dst[i] = ntohl(dst[i]);
	
	return dst;
}


// http://burtleburtle.net/bob/hash/doobs.html
// Bob Jenkins' one-at-a-time hash function
static inline uint32_t one_at_a_time_hash32(const uint8_t *key, size_t len)
{
	uint32_t   hash = 0;
	for (size_t i=0; i<len; ++i)
	{
		hash += key[i];
		hash += (hash << 10);
		hash ^= (hash >> 6);
	}
	hash += (hash << 3);
	hash ^= (hash >> 11);
	hash += (hash << 15);
	return hash;
}

@interface NSSet (FoundationExtensions)

- (NSSet*) xorSetWithSet: (NSSet*) set;

@end

@interface NSDictionary (FoundationExtensions)

- (NSDictionary*) dictionaryBySettingObject: (id) obj forKey: (id<NSCopying>) key;
- (NSDictionary*) dictionaryByRemovingObjectForKey: (id<NSCopying>) key;

@end

#define SuppressPerformSelectorLeakWarning(Stuff) \
do { \
_Pragma("clang diagnostic push") \
_Pragma("clang diagnostic ignored \"-Warc-performSelector-leaks\"") \
Stuff; \
_Pragma("clang diagnostic pop") \
} while (0)

#define SuppressSelfCaptureWarning(Stuff) \
do { \
_Pragma("clang diagnostic push") \
_Pragma("clang diagnostic ignored \"-Warc-retain-cycles\"") \
Stuff; \
_Pragma("clang diagnostic pop") \
} while (0)
