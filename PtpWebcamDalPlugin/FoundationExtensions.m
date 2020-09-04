//
//  FoundationExtensions.m
//  common
//
//  Created by Dömötör Gulyás on 18.01.12.
//  Copyright (c) 2012-2020 Doemoetoer Gulyas. All rights reserved.
//

#import "FoundationExtensions.h"

dispatch_source_t dispatch_coalesce_source_create(dispatch_queue_t queue)
{
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
	dispatch_resume(src);
	return src;
}

void dispatch_coalesce(dispatch_source_t src, double time, void (^block)(void))
{
	dispatch_source_set_timer(src, dispatch_time(DISPATCH_TIME_NOW, time * NSEC_PER_SEC), DISPATCH_TIME_FOREVER, 0);
	dispatch_source_set_event_handler(src, block);
}


@implementation NSArray (FoundationExtensions)

- (NSArray *)map: (id (^)(id obj))block
{
	NSMutableArray *new = [[NSMutableArray alloc] initWithCapacity: [self count]];
	for(id obj in self)
	{
		@autoreleasepool {
			id newObj = block(obj);
			[new addObject: newObj ? newObj : [NSNull null]];
		}
	}
	return new;
}

- (NSArray *) indexedMap: (id (^)(id obj, NSInteger index))block
{
	NSMutableArray *new = [[NSMutableArray alloc] initWithCapacity: [self count]];
	NSInteger i = 0;
	for(id obj in self)
	{
		id newObj = block(obj, i);
		[new addObject: newObj ? newObj : [NSNull null]];
		++i;
	}
	return new;
}

- (NSArray*) select: (BOOL (^)(id obj)) block
{
	NSMutableArray *new = [[NSMutableArray alloc] initWithCapacity: [self count]];
	for(id obj in self)
	{
		BOOL keep = block(obj);
		if (keep)
			[new addObject: obj];
	}
	return new;

}

- (NSArray*) arrayByRemovingObjectsAtIndexes: (NSIndexSet*) indexes
{
	NSMutableArray* ary = [self mutableCopy];
	[ary removeObjectsAtIndexes: indexes];
	return ary;
}

- (NSArray*) arrayByInsertingObjects: (NSArray*) objects atIndexes: (NSIndexSet*) indexes
{
	NSMutableArray* ary = [self mutableCopy];
	
	[ary insertObjects: objects atIndexes: indexes];
	
	return ary;
}
- (NSArray*) arrayByInsertingObject:(id)obj atIndex:(NSUInteger)index
{
	NSMutableArray* ary = [self mutableCopy];
	[ary insertObject: obj  atIndex: index];
	return ary;
}

- (NSArray*) arrayByRemovingObject:(id)obj
{
	NSMutableArray* ary = [self mutableCopy];
	[ary removeObject: obj];
	return ary;
}

- (NSArray*) arrayByRemovingObjectsInArray: (NSArray*) ary
{
	NSMutableArray* result = [self mutableCopy];
	[result removeObjectsInArray: ary];
	return result;
}
- (NSArray*) arrayByRemovingLastObject
{
	NSMutableArray* result = [self mutableCopy];
	[result removeLastObject];
	return result;
}

- (NSArray*) arraysBySlicingAfterLimit: (NSUInteger) numLimit
{
	NSMutableArray* array = [NSMutableArray arrayWithCapacity: self.count/numLimit+1];
	NSUInteger numSlices = ((self.count+numLimit-1)/numLimit);
	for (NSUInteger i = 0; i < numSlices; ++i)
		[array addObject: [[NSMutableArray alloc] init]];

	[self enumerateObjectsUsingBlock: ^(id obj, NSUInteger idx, BOOL *stop) {
		[[array objectAtIndex: idx/numLimit] addObject: obj];
	}];

	
	return array;
}

- (NSArray*) arraysByDeinterleavingColumns: (NSUInteger) numColumns
{
	NSMutableArray* columns = [NSMutableArray arrayWithCapacity: numColumns];
	for (NSUInteger i = 0; i < numColumns; ++i)
		[columns addObject: [[NSMutableArray alloc] init]];
	
	[self enumerateObjectsUsingBlock: ^(id obj, NSUInteger idx, BOOL *stop) {
		[[columns objectAtIndex: (idx % numColumns)] addObject: obj];
	}];
	
	return columns;
}

@end


@implementation NSSet (FoundationExtensions)

- (NSSet*) xorSetWithSet: (NSSet*) set
{
	NSMutableSet* a = [self mutableCopy];
	NSMutableSet* b = [set mutableCopy];
	[a minusSet: set];
	[b minusSet: self];
	[a unionSet: b];
	return a;
}

@end

@implementation NSDictionary (FoundationExtensions)

- (NSDictionary*) dictionaryBySettingObject: (id) obj forKey: (id<NSCopying>) key
{
	NSMutableDictionary* dict = [self mutableCopy];
	[dict setObject: obj forKey: key];
	return dict;
}

- (NSDictionary*) dictionaryByRemovingObjectForKey: (id<NSCopying>) key
{
	NSMutableDictionary* dict = [self mutableCopy];
	[dict removeObjectForKey: key];
	return dict;

}

@end






