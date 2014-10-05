//
//  QuadMap.m
//  OpenStreetMap
//
//  Created by Bryce Cogswell on 10/10/12.
//  Copyright (c) 2012 Bryce Cogswell. All rights reserved.
//

#import "OsmObjects.h"
#import "QuadMap.h"
#import "UndoManager.h"


static const double MinRectSize = 360.0 / (1 << 16);

static const OSMRect MAP_RECT = { -180, -90, 360, 180 };


@implementation QuadBox
@synthesize rect = _rect;

-(instancetype)initWithRect:(OSMRect)rect parent:(QuadBox *)parent;
{
	self = [super init];
	if ( self ) {
		_rect = rect;
		_parent = parent;
	}
	return self;
}

-(instancetype)init
{
	return [self initWithRect:MAP_RECT parent:nil];
}

-(void)reset
{
	_children[ 0 ] = nil;
	_children[ 1 ] = nil;
	_children[ 2 ] = nil;
	_children[ 3 ] = nil;
	_whole	= NO;
	_busy = NO;
	_members = nil;
	_isSplit = NO;
}


static inline OSMRect ChildRect( QUAD_ENUM child, OSMRect parent )
{
	assert(child <= QUAD_LAST);
	switch ( child ) {
		case QUAD_NW:
			return OSMRectMake(parent.origin.x, parent.origin.y, parent.size.width*0.5, parent.size.height*0.5);
		case QUAD_SW:
			return OSMRectMake(parent.origin.x, parent.origin.y+parent.size.height*0.5, parent.size.width*0.5, parent.size.height*0.5);
		case QUAD_SE:
			return OSMRectMake(parent.origin.x+parent.size.width*0.5, parent.origin.y+parent.size.height*0.5, parent.size.width*0.5, parent.size.height*0.5);
		case QUAD_NE:
			return OSMRectMake(parent.origin.x+parent.size.width*0.5, parent.origin.y, parent.size.width*0.5, parent.size.height*0.5);
	}
}

-(void)missingPieces:(NSMutableArray *)pieces intersectingRect:(OSMRect)target
{
	if ( _whole || _busy )
		return;
	if ( ! OSMRectIntersectsRect(target, _rect ) )
		return;
	if ( _rect.size.width <= MinRectSize || _rect.size.width <= target.size.width/8 ) {
		_busy = YES;
		[pieces addObject:self];
		return;
	}
	if ( OSMRectContainsRect(target, _rect) ) {
		if ( _children[0] == nil && _children[1] == nil && _children[2] == nil && _children[3] == nil ) {
			_busy = YES;
			[pieces addObject:self];
			return;
		}
	}

	for ( QUAD_ENUM child = 0; child <= QUAD_LAST; ++child ) {
		OSMRect rc = ChildRect( child, _rect );
		if ( OSMRectIntersectsRect( target, rc ) ) {

			if ( _children[child] == nil ) {
				_children[child] = [[QuadBox alloc] initWithRect:rc parent:self];
			}

			[_children[child] missingPieces:pieces intersectingRect:target];
		}
	}
}

// This runs after we attempted to download a quad.
// If the download succeeded we can mark this region and its children as whole.
-(void)makeWhole:(BOOL)success
{
	assert(_parent);
	if ( _parent->_whole ) {
		// parent was made whole (somehow) before we completed, so nothing to do
		return;
	}

#if DEBUG
	BOOL isCorrectChild = NO;
	for ( QUAD_ENUM child = 0; child <= QUAD_LAST; ++child ) {
		if ( self == _parent->_children[child] ) {
			isCorrectChild = YES;
			break;
		}
	}
	assert( isCorrectChild );
#endif

	if ( success ) {
		_whole = YES;
		_busy = NO;
		for ( QUAD_ENUM child = 0; child <= QUAD_LAST; ++child ) {
			_children[child] = nil;
		}
		for ( QUAD_ENUM child = 0; child <= QUAD_LAST; ++child ) {
			QuadBox * c = _parent->_children[child];
			if ( c == nil || !c->_whole )
				return;
		}
		[_parent makeWhole:success];
	} else {
		_busy = NO;
	}
}

-(void)enumerateWithBlock:(void (^)(QuadBox * quad))block
{
	block(self);
	for ( QUAD_ENUM child = 0; child <= QUAD_LAST; ++child ) {
		QuadBox * q = _children[ child ];
		if ( q ) {
			[q enumerateWithBlock:block];
		}
	}
}

-(NSInteger)quadCount
{
	__block NSInteger c = 0;
	[self enumerateWithBlock:^(QuadBox *quad) {
		++c;
	}];
	return c;
}
-(NSInteger)memberCount
{
	__block NSInteger c = 0;
	[self enumerateWithBlock:^(QuadBox *quad) {
		c += quad->_members.count;
	}];
	return c;
}

static const NSInteger MAX_MEMBERS_PER_LEVEL = 16;

// return YES if object was added, NO if it already existed in the appropriate quad
-(BOOL)addMember:(OsmBaseObject *)member bbox:(OSMRect)bbox
{
	if ( !_isSplit && _members.count < MAX_MEMBERS_PER_LEVEL ) {
		if ( _members == nil ) {
			_members = [NSMutableArray arrayWithObject:member];
			return YES;
		} else {
			if ( [_members containsObject:member] )
				return NO;
			[_members addObject:member];
			return YES;
		}
	}
	if ( !_isSplit ) {
		// split self
		_isSplit = YES;
		NSArray * childList = _members;
		_members = nil;
		for ( OsmBaseObject * c in childList ) {
			[self addMember:c bbox:c.boundingBox];
		}
	}
	// find a child member could fit into
	NSInteger index = -1;
	for ( QUAD_ENUM child = 0; child <= QUAD_LAST; ++child ) {
		OSMRect rc = ChildRect( child, _rect );
		if ( OSMRectIntersectsRect( bbox, rc ) ) {
			if ( index < 0 ) {
				index = child;	// item crosses this child
			} else {
				index = -1;		// item crosses multiple children, so has to stay in parent
				break;
			}
		}
	}
	if ( index >= 0 ) {
		// add to child quad
		if ( _children[index] == nil ) {
			OSMRect rc = ChildRect( (QUAD_ENUM)index, _rect );
			_children[index] = [[QuadBox alloc] initWithRect:rc parent:self];
		}
		return [_children[index] addMember:member bbox:bbox];
	} else {
		// add to self
		if ( _members == nil ) {
			_members = [NSMutableArray arrayWithObject:member];
			return YES;
		} else {
			if ( [_members containsObject:member] )
				return NO;
			[_members addObject:member];
			return YES;
		}
	}
}

-(BOOL)removeMember:(OsmBaseObject *)member bbox:(OSMRect)bbox
{
	if ( [_members containsObject:member] ) {
		[_members removeObject:member];
		return YES;
	}
	// find a child member could fit into
	for ( QUAD_ENUM child = 0; child <= QUAD_LAST; ++child ) {
		OSMRect rc = ChildRect( child, _rect );
		if ( OSMRectIntersectsRect( bbox, rc ) ) {
			if ( [_children[child] removeMember:member bbox:bbox] )
				return YES;
		}
	}
	return NO;
}



-(void)findObjectsInArea:(OSMRect)bbox block:(void (^)(OsmBaseObject * object))block
{
	for ( OsmBaseObject * obj in _members ) {
		if ( [obj overlapsBox:bbox] )
			block( obj );
	}
	for ( QUAD_ENUM c = 0; c <= QUAD_LAST; ++c ) {
		QuadBox * child = _children[ c ];
		if ( child && OSMRectIntersectsRect( bbox, child->_rect ) ) {
			[child findObjectsInArea:bbox block:block];
		}
	}
}



-(void)encodeWithCoder:(NSCoder *)coder
{
	[coder encodeObject:_children[0]					forKey:@"child0"];
	[coder encodeObject:_children[1]					forKey:@"child1"];
	[coder encodeObject:_children[2]					forKey:@"child2"];
	[coder encodeObject:_children[3]					forKey:@"child3"];
	[coder encodeObject:_parent							forKey:@"parent"];
	[coder encodeBool:_whole							forKey:@"whole"];
	[coder encodeObject:[NSData dataWithBytes:&_rect length:sizeof _rect]	forKey:@"rect"];
	[coder encodeObject:_members						forKey:@"members"];
	[coder encodeBool:_isSplit							forKey:@"split"];
}
-(id)initWithCoder:(NSCoder *)coder
{
	self = [super init];
	if ( self ) {
		_children[0]	= [coder decodeObjectForKey:@"child0"];
		_children[1]	= [coder decodeObjectForKey:@"child1"];
		_children[2]	= [coder decodeObjectForKey:@"child2"];
		_children[3]	= [coder decodeObjectForKey:@"child3"];
		_parent			= [coder decodeObjectForKey:@"parent"];
		_whole			= [coder decodeBoolForKey:@"whole"];
		_isSplit		= [coder decodeBoolForKey:@"split"];
		_rect			= *(OSMRect *)[[coder decodeObjectForKey:@"rect"] bytes];
		_members		= [coder decodeObjectForKey:@"members"];
	}
	return self;
}

@end


@implementation QuadMap

-(instancetype)initWithRect:(OSMRect)rect
{
	self = [super init];
	if ( self ) {
		_rootQuad = [[QuadBox alloc] initWithRect:rect parent:nil];
	}
	return self;
}

-(instancetype)init
{
	return [self initWithRect:MAP_RECT];
}

-(void)mergeDerivedRegion:(QuadMap *)other success:(BOOL)success
{
	assert( other.count == 1 );
	[self makeWhole:other->_rootQuad success:success];
}


-(NSArray *)newQuadsForRect:(OSMRect)newRect
{
	NSMutableArray * quads = [NSMutableArray new];

	assert( newRect.origin.x <= 180 && newRect.origin.x >= -180 );
	if ( newRect.origin.x + newRect.size.width > 180 ) {
		OSMRect half;
		half.origin.x = -180;
		half.size.width = newRect.origin.x + newRect.size.width - 180;
		half.origin.y = newRect.origin.y;
		half.size.height = newRect.size.height;
		[_rootQuad missingPieces:quads intersectingRect:half];
		newRect.size.width = 180 - newRect.origin.x;
	}
	[_rootQuad missingPieces:quads intersectingRect:newRect];
	return quads;
}


-(void)makeWhole:(QuadBox *)quad success:(BOOL)success
{
	[quad makeWhole:success];
}


-(void)addMember:(OsmBaseObject *)member
{
	OSMRect box = [member boundingBox];
	[_rootQuad addMember:member bbox:box];
}

-(void)removeMember:(OsmBaseObject *)member
{
	OSMRect box = [member boundingBox];
	[_rootQuad removeMember:member bbox:box];
}

-(void)addMember:(OsmBaseObject *)member undo:(UndoManager *)undo
{
	if ( undo ) {
		[undo registerUndoWithTarget:self selector:@selector(removeMember:undo:) objects:@[member,undo]];
	}
	[self.rootQuad addMember:member bbox:member.boundingBox];
}
-(BOOL)removeMember:(OsmBaseObject *)member undo:(UndoManager *)undo
{
	BOOL ok = [self.rootQuad removeMember:member bbox:member.boundingBox];
	if ( ok && undo ) {
		[undo registerUndoWithTarget:self selector:@selector(addMember:undo:) objects:@[member,undo]];
	}
	return ok;
}
-(void)updateMember:(OsmBaseObject *)member toBox:(OSMRect)toBox fromBox:(OSMRect)fromBox undo:(UndoManager *)undo
{
	BOOL added = [self.rootQuad addMember:member bbox:toBox];
	if ( added ) {
		BOOL removed = [self.rootQuad removeMember:member bbox:fromBox];
		if ( undo ) {
			if ( removed ) {
				NSData * to = [NSData dataWithBytes:&toBox length:sizeof toBox];
				NSData * from = [NSData dataWithBytes:&fromBox length:sizeof fromBox];
				[undo registerUndoWithTarget:self selector:@selector(updateMemberBoxed:toBox:fromBox:undo:) objects:@[member,from,to,undo]];
			} else {
				[undo registerUndoWithTarget:self selector:@selector(removeMember:undo:) objects:@[member,undo]];
			}
		}
	} else {
		// it ended up in the same quad as before
	}
}
-(void)updateMemberBoxed:(OsmBaseObject *)member toBox:(NSData *)toBox fromBox:(NSData *)fromBox undo:(UndoManager *)undo
{
	const OSMRect * to = (const OSMRect *)toBox.bytes;
	const OSMRect * from = (const OSMRect *)fromBox.bytes;
	[self updateMember:member toBox:*to fromBox:*from undo:undo];
}
-(void)updateMember:(OsmBaseObject *)member fromBox:(OSMRect)bbox undo:(UndoManager *)undo
{
	[self updateMember:member toBox:member.boundingBox fromBox:bbox undo:undo];
}





-(void)findObjectsInArea:(OSMRect)bbox block:(void (^)(OsmBaseObject *))block
{
	[_rootQuad findObjectsInArea:bbox block:block];
}



-(void)enumerateWithBlock:(void (^)(QuadBox * quad))block
{
	[_rootQuad enumerateWithBlock:block];
}

-(NSInteger)count
{
	__block NSInteger c = 0;
	[self enumerateWithBlock:^(QuadBox * quad){
		++c;
	}];
	return c;
}

-(void)encodeWithCoder:(NSCoder *)coder
{
	[coder encodeObject:_rootQuad forKey:@"rootQuad"];
}
-(id)initWithCoder:(NSCoder *)coder
{
	self = [super init];
	if ( self ) {
		_rootQuad	= [coder decodeObjectForKey:@"rootQuad"];
	}
	return self;
}

@end
