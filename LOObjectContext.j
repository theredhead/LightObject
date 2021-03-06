/*!
   LOObjectContext.j
 *
 * Created by Martin Carlberg on Feb 23, 2012.
 * Copyright 2012, All rights reserved.
 */

@import <Foundation/CPObject.j>
@import <Foundation/CPNotificationCenter.j>
@import "LOJSKeyedArchiver.j"
@import "LOFetchSpecification.j"
@import "LOObjectStore.j"
@import "LOSimpleJSONObjectStore.j"
@import "LOEvent.j"
@import "LOError.j"
@import "LOFault.j"

@class LOFaultObject

LOObjectContextReceivedObjectNotification = @"LOObjectContextReceivedObjectNotification";
LOObjectsKey = @"LOObjectsKey";

var LOObjectContext_classForType = 1 << 0,
    LOObjectContext_objectContext_objectsReceived_withFetchSpecification = 1 << 1,
    LOObjectContext_objectContext_didValidateProperty_withError = 1 << 2,
    LOObjectContext_objectContext_shouldSaveChanges_withObject_inserted = 1 << 3,
    LOObjectContext_objectContext_didSaveChangesWithResultAndStatus = 1 << 4,
    LOObjectContext_objectContext_errorReceived_withFetchSpecification = 1 << 5,
    LOObjectContext_willRequestFaultArray_withFetchSpecification_withRequestId = 1 << 6,
    LOObjectContext_didRequestFaultArray_withFetchSpecification_withRequestId = 1 << 7,
    LOObjectContext_willRequestFaultObjects_withFetchSpecification_withRequestId = 1 << 8,
    LOObjectContext_didRequestFaultObjects_withFetchSpecification_withRequestId = 1 << 9;


@implementation LOModifyRecord : CPObject {
    id              object @accessors;          // The object that is changed
    CPString        tmpId @accessors;           // Temporary id for object if LOObjectStore needs to keep track on it.
    CPDictionary    insertDict @accessors;      // A dictionary with attributes when the object is created
    CPDictionary    updateDict @accessors;      // A dictionary with attributes when the object is updated
    CPDictionary    deleteDict @accessors;      // A dictionary with attributes when the object is deleted (will allways be empty)
}

+ (LOModifyRecord) modifyRecordWithObject:(id) theObject {
    return [[LOModifyRecord alloc] initWithObject:theObject];
}

- (id)initWithObject:(id) theObject {
    self = [super init];
    if (self) {
        object = theObject;
    }
    return self;
}

- (BOOL) isEmpty {
    return (!insertDict || [insertDict count] === 0) && (!updateDict || [updateDict count] === 0) && !deleteDict;
}

- (CPString)description {
    return [CPString stringWithFormat:@"<LOModifyRecord insertDict: %@ updateDict: %@ deleteDict: %@ object: %@>", insertDict, updateDict, deleteDict, object];
}

@end


@class LOObjectContext;

@implementation LOToOneProxyObject : CPObject {
    LOObjectContext objectContext;
}

+ (LOToOneProxyObject) toOneProxyObjectWithContext:(LOObjectContext) anObjectContext {
    return [[LOToOneProxyObject alloc] initWithContext:anObjectContext];
}

- (id)initWithContext:(LOObjectContext) anObjectContext {
    self = [super init];
    if (self) {
        objectContext = anObjectContext;
    }
    return self;
}

- (void)observeValueForKeyPath:(CPString)theKeyPath ofObject:(id)theObject change:(CPDictionary)theChanges context:(id)theContext {
    //CPLog.trace(_cmd + @" observeValueForToOneRelationshipWithKeyPath:" + theKeyPath +  @" object:" + theObject + @" change:" + theChanges);
    [objectContext observeValueForToOneRelationshipWithKeyPath: theKeyPath ofObject:theObject change:theChanges context:theContext];
}

@end

/*!
 @ingroup LightObject
 @class LOObjectContext

     LOObjectContext represents a single "object space" or document in an application. Its primary responsibility is managing a graph of objects. This object graph is a group of related business objects that represent an internally consistent view of one object store.

     All objects fetched from an object store are registered in an LOObjectContext along with a global identifier (LOGlobalID)(LOGlobalID not yet implemented) that's used to uniquely identify each object to the object store. The LOObjectContext is responsible for watching for changes in its objects (using the CPKeyValueObserving protocol). A single object instance exists in one and only one LOObjectContext.

     The object context observes all changes of the object graph except toMany relations. The caller is responsible to use the add:toRelationshipWithKey:forObject: or delete:withRelationshipWithKey:forObject: method to let the object context know about changes in tomany relations.

     A LOArrayController can keep track of changes in tomany relations and make sure that the add:toRelationshipWithKey:forObject: or delete:withRelationshipWithKey:forObject: method is used appropriate.

     The framework supports "fault" and "deep fetch" for tomany relations. The backend can send a fault or an array with type and primary key values for a deep fetch. In a "deep fetch" the rows corresponding to the tomany relationship should be sent together with the fetched objects (in the same list).

     When a fetch is requested with the requestObjectsWithFetchSpecification: method the answer is later sent with the delegate method objectContext:objectsReceived:withFetchSpecification: or sent as the notification LOObjectContextReceivedObjectNotification with the fetch specification as object and result in userInfo.

     When a fault is triggered the notification LOFaultDidFireNotification is sent and when it is received the notification LOFaultDidPopulateNotification is sent.

     Right now the global id is the same as the primary key. A primary key has to be unique for all objects in the object context.

 @delegate -(void)objectContext:(LOObjectContext)anObjectContext objectsReceived:(CPArray)objects withFetchSpecification:(LOFetchSpecification)aFetchSpecification;
 Receives objects from an fetch request specified by the fetch specification.
 @param anObjectContext contains the object context
 @param objects contains the received objects
 @param aFetchSpecification contains the fetch specification

 @delegate -(void)objectContext:(LOObjectContext)anObjectContext errorReceived:(LOError)anError withFetchSpecification:(LOFetchSpecification)aFetchSpecification;
 Receives error from an fetch request specified by the fetch specification.
 @param anObjectContext contains the object context
 @param anError contains the error
 @param aFetchSpecification contains the fetch specification

 //TODO: Add more delegate methods to this documentation
 */

// Debug modes. Set the 'dubugMode' instance variable to receive useful debug information.
LOObjectContextDebugModeFetch = 1 << 0;
LOObjectContextDebugModeSaveChanges = 1 << 1;
LOObjectContextDebugModeReceiveData = 1 << 2;
LOObjectContextDebugModeObserveValue = 1 << 3;
LOObjectContextDebugModeAllInfo = ~0;

@implementation LOObjectContext : CPObject {
    LOObjectContext     sharedObjectContext @accessors; // A read only object context that can be shared between many object contexts
    LOToOneProxyObject  toOneProxyObject;               // Extra observer proxy for to one relation attributes
    CPDictionary        objects;                        // List of all objects in context with globalId as key
    CPArray             modifiedObjects @accessors;     // Array of LOModifyRecords with "insert", "update" and "delete" dictionaries.
    CPArray             undoEvents;                     // Array of arrays with LOUpdateEvents. Each transaction has its own array.
    CPArray             connections;                    // Array of dictionary with connection: CPURLConnection and arrayController: CPArrayController
    @outlet id          delegate;
    @outlet LOObjectStore objectStore @accessors;
    CPInteger           implementedDelegateMethods;
    BOOL                autoCommit @accessors;          // True if the context should directly save changes to object store.
    BOOL                doNotObserveValues @accessors;  // True if observeValueForKeyPath methods should ignore chnages. Used when doing revert
    BOOL                readOnly;                       // True if object context is a read only context. A read only context don't listen to changes for the attributes on the objects
    BOOL                addRelationshipAsUpdate @accessors; // True if to many relationship should be added as an update even when it is an insert. This can help the backend if it needs to resolve a newly inserted object before it can add it as a relationship.

    CPMutableDictionary faultObjectRequests;

    int                 debugMode @accessors;           // None zero if object context should do a CPLog.trace() with the JSON data sent and received. Nice for debugging. Look at the debug mode constants
}

- (id)init {
    self = [super init];
    if (self) {
        toOneProxyObject = [LOToOneProxyObject toOneProxyObjectWithContext:self];
        objects = [CPDictionary dictionary];
        modifiedObjects = [CPArray array];
        connections = [CPArray array];
        autoCommit = YES;
        undoEvents = [CPArray array];
        doNotObserveValues = NO;
        readOnly = NO;
        addRelationshipAsUpdate = YES;
        debugMode = 0;
        faultObjectRequests = [CPMutableDictionary dictionary];
    }
    return self;
}

- (id)initWithDelegate:(id) aDelegate {
    self = [self init];
    if (self) {
        [self setDelegate:aDelegate];
    }
    return self;
}

- (void)setDelegate:(id)aDelegate {
    if (delegate === aDelegate)
        return;
    delegate = aDelegate;
    implementedDelegateMethods = 0;

    if ([delegate respondsToSelector:@selector(classForType:)])
        implementedDelegateMethods |= LOObjectContext_classForType;
    if ([delegate respondsToSelector:@selector(objectContext:objectsReceived:withFetchSpecification:)])
        implementedDelegateMethods |= LOObjectContext_objectContext_objectsReceived_withFetchSpecification;
    if ([delegate respondsToSelector:@selector(objectContext:didValidateProperty:withError:)])
        implementedDelegateMethods |= LOObjectContext_objectContext_didValidateProperty_withError;
    if ([delegate respondsToSelector:@selector(objectContext:shouldSaveChanges:withObject:inserted:)])
        implementedDelegateMethods |= LOObjectContext_objectContext_shouldSaveChanges_withObject_inserted;
    if ([delegate respondsToSelector:@selector(objectContext:didSaveChangesWithResult:andStatus:)])
        implementedDelegateMethods |= LOObjectContext_objectContext_didSaveChangesWithResultAndStatus;
    if ([delegate respondsToSelector:@selector(objectContext:errorReceived:withFetchSpecification:)])
        implementedDelegateMethods |= LOObjectContext_objectContext_errorReceived_withFetchSpecification;
    if ([delegate respondsToSelector:@selector(willRequestFaultArray:withFetchSpecification:withRequestId:)])
        implementedDelegateMethods |= LOObjectContext_willRequestFaultArray_withFetchSpecification_withRequestId;
    if ([delegate respondsToSelector:@selector(didRequestFaultArray:withFetchSpecification:withRequestId:)])
        implementedDelegateMethods |= LOObjectContext_didRequestFaultArray_withFetchSpecification_withRequestId;
    if ([delegate respondsToSelector:@selector(willRequestFaultObjects:withFetchSpecification:withRequestId:)])
        implementedDelegateMethods |= LOObjectContext_willRequestFaultObjects_withFetchSpecification_withRequestId;
    if ([delegate respondsToSelector:@selector(didRequestFaultObjects:withFetchSpecification:withRequestId:)])
        implementedDelegateMethods |= LOObjectContext_didRequestFaultObjects_withFetchSpecification_withRequestId;
}

- (BOOL)readOnly {
    return readOnly;
}

- (void)setReadOnly:(BOOL)aValue {
    // TODO: Add or remove observers for the objects in the context. Now we can only set read only for an empty context
    if ([objects count] && aValue !== readOnly) {
        CPLog.error(@"[" + [self className] + @" " + _cmd + @"] Can't change the Read Only state of a Object Context when there are objects registered in the context. Number of registered objects: " + [objects count]);
    } else {
        readOnly = aValue;
    }
}

- (void)callCompletionBlocks:(CPArray)completionBlocks withObject:(id)arrayOrObject andStatus:(int)statusCode {
    if (completionBlocks) {
        var size = [completionBlocks count];
        for (var i = 0; i < size; i++) {
            var aCompletionBlock = [completionBlocks objectAtIndex:i];
            aCompletionBlock(arrayOrObject, statusCode);
        }
    }
}

/*!
 This method will create a new object. Always use this method to create a object for a object context
 */
- (id)createNewObjectForType:(CPString)type {
    return [objectStore newObjectForType:type objectContext:self];
}

/*!
 This method will ask the delegate for a class and create an object. Never use this method directly to create a new object, use the createNewObjectForType: method instead.
 */
- (id)newObjectForType:(CPString)type {
    if (implementedDelegateMethods & LOObjectContext_classForType) {
        var aClass = [delegate classForType:type];
        return [[aClass alloc] init];
    } else {
        CPLog.error(@"[" + [self className] + @" " + _cmd + @"]: Delegate must implement selector classForType: to be able to create new object of type: " + type);
    }
    return nil;
}

- (CPArray)requestObjectsWithFetchSpecification:(LOFetchSpecification)aFetchSpecification withRequestId:(id)aRequestId withCompletionHandler:(Function/*(resultArray, statusCode)*/)aCompletionBlock {
    [objectStore requestObjectsWithFetchSpecification:aFetchSpecification objectContext:self requestId:aRequestId withCompletionHandler:aCompletionBlock];
}

- (CPArray)requestObjectsWithFetchSpecification:(LOFetchSpecification)aFetchSpecification withCompletionHandler:(Function/*(resultArray, statusCode)*/)aCompletionBlock {
    [self requestObjectsWithFetchSpecification:aFetchSpecification withRequestId:nil withCompletionHandler:aCompletionBlock];
}

- (CPArray)requestObjectsWithFetchSpecification:(LOFetchSpecification)aFetchSpecification {
    [self requestObjectsWithFetchSpecification:aFetchSpecification withRequestId:nil withCompletionHandler:nil];
}

- (CPArray)requestFaultArray:(LOFaultArray)faultArray withFetchSpecification:(LOFetchSpecification)fetchSpecification withRequestId:(id)requestId withCompletionHandler:(Function/*(resultArray, statusCode)*/)aCompletionBlock {
    if (implementedDelegateMethods & LOObjectContext_willRequestFaultArray_withFetchSpecification_withRequestId
        && ![delegate willRequestFaultArray:faultArray withFetchSpecification:fetchSpecification withRequestId:requestId]) {
        return;
    }
    [objectStore requestFaultArray:faultArray withFetchSpecification:fetchSpecification objectContext:self requestId:requestId withCompletionHandler:aCompletionBlock];
    if (implementedDelegateMethods & LOObjectContext_didRequestFaultArray_withFetchSpecification_withRequestId) {
        [delegate didRequestFaultArray:faultArray withFetchSpecification:fetchSpecification withRequestId:requestId];
    }
}

- (CPArray)requestFaultArray:(LOFaultArray)faultArray withFetchSpecification:(LOFetchSpecification)fetchSpecification withCompletionHandler:(Function/*(resultArray, statusCode)*/)aCompletionBlock {
    [self requestFaultArray:faultArray withFetchSpecification:fetchSpecification withRequestId:nil withCompletionHandler:aCompletionBlock];
}

- (void)requestFaultObject:(LOFaultObject)aFaultObject withRequestId:(id)aRequestId withCompletionHandler:(Function)aCompletionBlock {
    var entityName = aFaultObject.entityName;
    var doTheFetch = function() {
        var faultObjectRequestsForEntity = [faultObjectRequests objectForKey:entityName];
        var primaryKeyAttribute = [objectStore primaryKeyAttributeForType:entityName objectContext:self];
        var qualifier = [CPComparisonPredicate predicateWithLeftExpression:[CPExpression expressionForKeyPath:primaryKeyAttribute]
                                                           rightExpression:[CPExpression expressionForConstantValue:[faultObjectRequestsForEntity valueForKey:primaryKeyAttribute]]
                                                                  modifier:CPDirectPredicateModifier
                                                                      type:CPInPredicateOperatorType
                                                                   options:0];
        var fetchSpecification = [LOFetchSpecification fetchSpecificationForEntityNamed:entityName qualifier:qualifier];
        if (implementedDelegateMethods & LOObjectContext_willRequestFaultObjects_withFetchSpecification_withRequestId
            && ![delegate willRequestFaultObjects:faultObjectRequestsForEntity withFetchSpecification:fetchSpecification withRequestId:aRequestId]) {
            return;
        }
        [objectStore requestFaultObjects:faultObjectRequestsForEntity withFetchSpecification:fetchSpecification objectContext:self requestId:aRequestId withCompletionHandler:aCompletionBlock];
        [faultObjectRequests removeObjectForKey:entityName];
        if (implementedDelegateMethods & LOObjectContext_didRequestFaultObjects_withFetchSpecification_withRequestId) {
            [delegate didRequestFaultObjects:faultObjectRequestsForEntity withFetchSpecification:fetchSpecification withRequestId:aRequestId];
        }
    }
    var faultObjectRequestsForEntity = [faultObjectRequests objectForKey:entityName];
    // If there are more then 100 fetch now to keep it small. TODO: Make this number controllable from outside
    if (faultObjectRequestsForEntity) {
        if ([faultObjectRequestsForEntity count] > 100) {
            doTheFetch();
            faultObjectRequestsForEntity = [];
            [faultObjectRequests setObject:faultObjectRequestsForEntity forKey:entityName];
        }
    } else {
        faultObjectRequestsForEntity = [];
        [faultObjectRequests setObject:faultObjectRequestsForEntity forKey:entityName];
        [self performSelector:@selector(performBlock:) withObject:doTheFetch afterDelay:0];
    }
    [faultObjectRequestsForEntity addObject:aFaultObject];
    [[CPNotificationCenter defaultCenter] postNotificationName:LOFaultDidFireNotification object:aFaultObject userInfo:nil];
}

- (void)requestFaultObject:(LOFaultObject)aFaultObject withCompletionHandler:(Function)aCompletionBlock {
    [self requestFaultObject:aFaultObject withRequestId:nil withCompletionHandler:aCompletionBlock];
}

/*!
 * Cancels requests related to the receiver matching aRequestId; or cancels all requests
 * related to the receiver if aRequestId is nil.
 *
 * Note: to cancel requests related to other object contexts, for example other
 * contexts sharing the same object store, either message the other contexts
 * or use the releated cancel methods on the shared object store.
 */
- (void)cancelRequestsWithRequestId:(id)aRequestId {
    [objectStore cancelRequestsWithRequestId:aRequestId withObjectContext:self];
}

- (void)performBlock:(Function)block {
    block();
}

- (void)objectsReceived:(CPArray)objectList allReceivedObjects:(CPArray)allReceivedObjects withFetchSpecification:(LOFetchSpecification)fetchSpecification withCompletionBlocks:(CPArray)completionBlocks {
    // FIXME: Maybe check if it is an array instead of if it responds to 'count'
    if (objectList.isa && [objectList respondsToSelector:@selector(count)]) {
        [self registerObjects:allReceivedObjects];
        [self awakeFromFetchForObjects:allReceivedObjects];
    }
    if (completionBlocks) {
        // FIXME: Here we hardcode the status code 200. Should be passed by the caller
        [self callCompletionBlocks:completionBlocks withObject:objectList andStatus:200];
    } else if (implementedDelegateMethods & LOObjectContext_objectContext_objectsReceived_withFetchSpecification) {
        [delegate objectContext:self objectsReceived:objectList withFetchSpecification:fetchSpecification];
    }
    var defaultCenter = [CPNotificationCenter defaultCenter];
    [defaultCenter postNotificationName:LOObjectContextReceivedObjectNotification object:fetchSpecification userInfo:[CPDictionary dictionaryWithObject:objectList forKey:LOObjectsKey]];
}

/*!
 * This is called when some objects are received from a fetch
 */
- (void)awakeFromFetchForObjects:(CPArray)objectArray {
    for (var i = 0, size = objectArray.length; i < size; i++) {
        var object = objectArray[i];
        if ([object respondsToSelector:@selector(awakeFromFetch:)]) {
            [object awakeFromFetch:self];
        }
    }
}

/*!
 * This is called when an object is inserted into the object context
 */
- (void)awakeFromInsertionForObject:(id <LOObject>)object {
    if ([object respondsToSelector:@selector(awakeFromInsertion:)]) {
        [object awakeFromInsertion:self];
    }
}

/*!
 * This is called when the result from a triggered fault is received
 */
- (void)faultReceived:(CPArray)objectList withFetchSpecification:(LOFetchSpecification)fetchSpecification withCompletionBlocks:(CPArray)completionBlocks faults:(id <LOFault>)faults {
    var faultDidPopulateNotificationUserInfos = [];
    for (var i = 0, size = [faults count]; i < size; i++) {
        var fault = [faults objectAtIndex:i];
        var faultDidPopulateNotificationUserInfo = [CPDictionary dictionaryWithObjects:[fault, fault.fetchSpecification] forKeys:[LOFaultKey, LOFaultFetchSpecificationKey]];

        [faultDidPopulateNotificationUserInfos addObject:faultDidPopulateNotificationUserInfo];
        [fault faultReceivedWithObjects:objectList];
    }

    // FIXME: Here we have hardcoded the status code. Should be passed from caller but it is always 200
    // FIXME: Here we pass the whole list of objects for object faults. It should be nicer if we just passed the corresponding object for each completion block. Right now we just keep a list of completion blocks and has no info about what fault it correspond to
    [self callCompletionBlocks:completionBlocks withObject:objectList andStatus:200];

    for (var i = 0, size = [faults count]; i < size; i++) {
        var fault = [faults objectAtIndex:i];
        var faultDidPopulateNotificationUserInfo = [faultDidPopulateNotificationUserInfos objectAtIndex:i];

        [[CPNotificationCenter defaultCenter] postNotificationName:LOFaultDidPopulateNotification object:fault userInfo:faultDidPopulateNotificationUserInfo];
    }
}

- (void)errorReceived:(LOError)error withFetchSpecification:(LOFetchSpecification)fetchSpecification result:(JSON)result statusCode:(int)statusCode completionBlocks:(CPArray)completionBlocks {
    if (completionBlocks)
        [self callCompletionBlocks:completionBlocks withObject:result andStatus:statusCode];
    if (implementedDelegateMethods & LOObjectContext_objectContext_errorReceived_withFetchSpecification) {
        [delegate objectContext:self errorReceived:error withFetchSpecification:fetchSpecification];
    }
}

- (void)observeValueForKeyPath:(CPString)theKeyPath ofObject:(id)theObject change:(CPDictionary)theChanges context:(id)theContext {
    if (doNotObserveValues) return;
    var newValue = [theChanges valueForKey:CPKeyValueChangeNewKey];
    var oldValue = [theChanges valueForKey:CPKeyValueChangeOldKey];
    if (newValue === oldValue) return;

    // If it is a new object all changed attributes are stored in the "insertDict"
    var dictType = [self isObjectStored:theObject] ? @"updateDict" : @"insertDict";
    var updateDict = [self subDictionaryForKey:dictType forObject:theObject];
    var updateEvent = [LOUpdateEvent updateEventWithObject:theObject updateDict:updateDict dictType:dictType key:theKeyPath old:oldValue new:newValue];
    [self registerEvent:updateEvent];

    if (!updateDict) {
        updateDict = [self createSubDictionaryForKey:dictType forModifyObjectDictionaryForObject:theObject];
    }

    [updateDict setObject:newValue !== nil ? newValue : [CPNull null] forKey:theKeyPath];

    if (debugMode & LOObjectContextDebugModeObserveValue) CPLog.trace(@"%@", @"LOObjectContextDebugModeObserveValue: Keypath: " + theKeyPath +  @" object:" + theObject + @" change:" + theChanges + @" " + dictType + @": " + [updateDict description]);

    // Simple validation handling
    if (implementedDelegateMethods & LOObjectContext_objectContext_didValidateProperty_withError && [theObject respondsToSelector:@selector(validatePropertyWithKeyPath:value:error:)]) {
        var validationError = [theObject validatePropertyWithKeyPath:theKeyPath value:theChanges error:validationError];
        if ([validationError domain] === [LOError LOObjectValidationDomainString]) {
            [delegate objectContext:self didValidateProperty:theKeyPath withError:validationError];
        }
    }

    if (autoCommit) [self saveChanges];
}

- (void)observeValueForToOneRelationshipWithKeyPath:(CPString)theKeyPath ofObject:(id)theObject change:(CPDictionary)theChanges context:(id)theContext {
    if (doNotObserveValues) return;
    var newValue = [theChanges valueForKey:CPKeyValueChangeNewKey];
    var oldValue = [theChanges valueForKey:CPKeyValueChangeOldKey];
    if (newValue === oldValue) return;
    if (newValue === [CPNull null])
        newValue = nil;
    var newGlobalId;
    var shouldSetForeignKey;       // We don't want to set a foreign key if the master object don't have a primary key.
    if (newValue) {
        if (![newValue isKindOfClass:LOFaultObject] && [objectStore primaryKeyForObject:newValue]) {
            shouldSetForeignKey = YES;
            newGlobalId = [self globalIdForObject:newValue];
        } else {
            shouldSetForeignKey = NO;
            newGlobalId = nil;
        }
    } else {
        shouldSetForeignKey = YES;
        newGlobalId = nil;
    }
    var oldGlobalId = [self globalIdForObject:oldValue];
    var foreignKey = [objectStore foreignKeyAttributeForToOneRelationshipAttribute:theKeyPath forType:[self typeOfObject:theObject]];
    // If it is a new object all changed attributes are stored in the "insertDict"
    var dictType = [self isObjectStored:theObject] ? @"updateDict" : @"insertDict";
    var updateDict = [self subDictionaryForKey:dictType forObject:theObject];
    var updateEvent = [LOToOneRelationshipUpdateEvent updateEventWithObject:theObject updateDict:updateDict dictType:dictType key:theKeyPath old:oldValue new:newValue foreignKey:foreignKey oldForeignValue:oldGlobalId newForeignValue:newGlobalId];
    [self registerEvent:updateEvent];

    if (!updateDict) {
        updateDict = [self createSubDictionaryForKey:dictType forModifyObjectDictionaryForObject:theObject];
    }

    if (shouldSetForeignKey) {
        [updateDict setObject:newGlobalId ? newGlobalId : [CPNull null] forKey:foreignKey];
    }

    if (debugMode & LOObjectContextDebugModeObserveValue) CPLog.trace(@"%@", @"LOObjectContextDebugModeObserveValue: Keypath: " + theKeyPath +  @" object:" + theObject + @" change:" + theChanges + @" " + dictType + @": " + [updateDict description]);

    if (autoCommit) [self saveChanges];
}

- (void)unregisterObject:(id) theObject {
    var globalId = [objectStore globalIdForObject:theObject];
    var type = [self typeOfObject:theObject];
    [objects removeObjectForKey:globalId];
    if (!readOnly) {
        var attributeKeys = [objectStore attributeKeysForObject:theObject withType:type];
        var relationshipKeys = [objectStore relationshipKeysForObject:theObject withType:type];
        var attributeSize = [attributeKeys count];
        for (var i = 0; i < attributeSize; i++) {
            var attributeKey = [attributeKeys objectAtIndex:i];
            if ([objectStore isForeignKeyAttribute:attributeKey forType:type objectContext:self]) {    // Handle to one relationship
                attributeKey = [objectStore toOneRelationshipAttributeForForeignKeyAttribute:attributeKey forType:type objectContext:self]; // Remove "_fk" at end
            }
            if (![relationshipKeys containsObject:attributeKey]) { // Not when it is a relationship
                [theObject removeObserver:self forKeyPath:attributeKey];
            }
        }
    }
}

- (void)unregisterAllObjects {
  [objects enumerateKeysAndObjectsUsingBlock:function(anId,anObject) {
      [self unregisterObject:anObject];
  }];
}

- (void)registerObject:(id)theObject {
    // TODO: Check if theObject is already registrered
    [self _registerObject:theObject forGlobalId:[objectStore globalIdForObject:theObject]];
    [self _observeAttributesForObject:theObject];
}

- (void)_observeAttributesForObject:(id)theObject {
    if (!readOnly) {
        var type = [self typeOfObject:theObject];
        var attributeKeys = [objectStore attributeKeysForObject:theObject withType:type];
        var relationshipKeys = [objectStore relationshipKeysForObject:theObject withType:type];
        var attributeSize = [attributeKeys count];
        for (var i = 0; i < attributeSize; i++) {
            var attributeKey = [attributeKeys objectAtIndex:i];
            if ([objectStore isForeignKeyAttribute:attributeKey forType:type objectContext:self]) {    // Handle to one relationship Make observation to proxy object and remove "_fk" from attribute key
                attributeKey = [objectStore toOneRelationshipAttributeForForeignKeyAttribute:attributeKey forType:type objectContext:self]; // Remove "_fk" at end
                [theObject addObserver:toOneProxyObject forKeyPath:attributeKey options:CPKeyValueObservingOptionNew | CPKeyValueObservingOptionOld context:nil];
            } else if (![relationshipKeys containsObject:attributeKey]) { // Not when it is a to many relationship
                [theObject addObserver:self forKeyPath:attributeKey options:CPKeyValueObservingOptionNew | CPKeyValueObservingOptionOld context:nil];
            }
        }
    }
}

- (void)_registerObject:(id)theObject forGlobalId:(CPString)globalId {
    [objects setObject:theObject forKey:globalId];
}

- (void)registerObjects:(CPArray)someObjects {
    var size = [someObjects count];
    for (var i = 0; i < size; i++) {
        var object = [someObjects objectAtIndex:i];
        if (![self isObjectRegistered:object]) {
            [self registerObject:object];
        }
    }
}

/*!
    Reregister the object with toGlobalId and removes it the old global id. This method asks the object for the current global id before the reregister. The caller is responseble to set the primary key afterward if necessary.
 */
- (void)reregisterObject:(id)theObject withNewGlobalId:(CPString)toGlobalId {
    var fromGlobalId = [self globalIdForObject:theObject];
    if (fromGlobalId) {
        [objects setObject:theObject forKey:toGlobalId];
        if (toGlobalId !== fromGlobalId)
            [objects removeObjectForKey:fromGlobalId];
    }
}

// TODO: Investigate why this method is implemented 2 times. (note 2013-09-30: according to commit logs this version is the latest. /malte).
/*!
    @return YES if theObject is stored by the object store and is registered in the context
    If you insert a new object to the object context this method will return NO until you send a saveChanges:
 */
- (BOOL)isObjectStored:(id)theObject {
    var globalId = [objectStore globalIdForObject:theObject];
    return [objects objectForKey:globalId] && ![self subDictionaryForKey:@"insertDict" forObject:theObject];
}

/*!
    @return YES if theObject is registered in the context
 */
- (BOOL)isObjectRegistered:(id)theObject {
    var globalId = [objectStore globalIdForObject:theObject];
    return [objects objectForKey:globalId] != nil;
}

/*!
    @return object to context
 */
- (id)objectForGlobalId:(CPString)globalId {
    return [self objectForGlobalId:globalId noFaults:NO];
}

/*!
    @return object to context
 */
- (id)objectForGlobalId:(CPString)globalId noFaults:(BOOL)noFaults {
    var obj = [objects objectForKey:globalId];
    if (obj == nil && sharedObjectContext) {
        return [sharedObjectContext objectForGlobalId:globalId noFaults:noFaults];
    }
    return noFaults && [obj conformsToProtocol:@protocol(LOFault)] ? nil : obj;
}

/*!
    @return global id for the Object. If it is not in the context nil is returned
 */
- (CPString)globalIdForObject:(id)theObject {
    if (theObject) {
        var globalId = [objectStore globalIdForObject:theObject];
        if ([objects objectForKey:globalId] || (sharedObjectContext && [sharedObjectContext objectForGlobalId:globalId noFaults:NO])) {
            return globalId;
        }
    }
    return nil;
}

/*!
    @return primary key for the Object. If it is not in the context nil is returned
 */
- (CPString)primaryKeyForObject:(id)theObject {
    if (theObject) {
        var globalId = [objectStore globalIdForObject:theObject];
        if ([objects objectForKey:globalId] || (sharedObjectContext && [sharedObjectContext objectForGlobalId:globalId noFaults:NO])) {
            return [objectStore primaryKeyForObject:theObject];
        }
    }
    return nil;
}

/*!
   Returns the type of the object
 */
- (CPString)typeOfObject:(id)theObject {
    return [objectStore typeOfObject:theObject];
}

- (void)_insertObject:(id)theObject {
    var type = [self typeOfObject:theObject];

    [self awakeFromInsertionForObject:theObject];
    // Just need to create the dict to mark it for insert
    var insertDict = [self createSubDictionaryForKey:@"insertDict" forModifyObjectDictionaryForObject:theObject];

    // Add attributes with values
    var attributeKeys = [objectStore attributeKeysForObject:theObject withType:type];
    var relationshipKeys = [objectStore relationshipKeysForObject:theObject withType:type];
    var attributeSize = [attributeKeys count];
    for (var i = 0; i < attributeSize; i++) {
        var attributeKey = [attributeKeys objectAtIndex:i];
        if ([objectStore isForeignKeyAttribute:attributeKey forType:type objectContext:self]) {    // Handle to one relationship. Make observation to proxy object and remove "_fk" from attribute key
            var toOneAttribute = [objectStore toOneRelationshipAttributeForForeignKeyAttribute:attributeKey forType:type objectContext:self]; // Remove "_fk" at end
            var value = [theObject valueForKey:toOneAttribute];
            if (value) {
                var globalId = [self globalIdForObject:value];
                if (globalId && [objectStore primaryKeyForObject:value]) {  // If the master object doesn't have a primary key don't set the foreign key
                    [insertDict setObject:globalId forKey:attributeKey];
                }
            }
        } else if (![relationshipKeys containsObject:attributeKey]) { // Not when it is a to many relationship
            var value = [theObject valueForKey:attributeKey];
            if (value) {
                [insertDict setObject:value forKey:attributeKey];
            }
        }
    }
    [self registerObject:theObject];
}

/*!
    Add object to context and add all non nil attributes as updated attributes
 */
- (void)insertObject:(id)theObject {
    [self _insertObject: theObject];
    var insertEvent = [LOInsertEvent insertEventWithObject:theObject arrayController:nil ownerObjects:nil ownerRelationshipKey:nil];
    [self registerEvent:insertEvent];
    if (autoCommit) [self saveChanges];
}

/*!
    Add objects to context
 */
- (void)insertObjects:(CPArray)theObjects {
    //FIXME: create delete event as in -insertObject:
    var size = [theObjects count];
    for (var i = 0; i < size; i++) {
        var obj = [theObjects objectAtIndex:i];
        [self _insertObject:obj];
    }
    if (autoCommit) [self saveChanges];
}

/*!
    Uninsert object to context. Used when doing undo
 */
- (void)unInsertObject:(id)theObject {
    [self _unInsertObject: theObject];
    if (autoCommit) [self saveChanges];
}

- (void) _unInsertObject:(id) theObject {
    if ([self subDictionaryForKey:@"insertDict" forObject:theObject]) {
        [self setSubDictionary:nil forKey:@"insertDict" forObject:theObject];
    } else {
        [self createSubDictionaryForKey:@"deleteDict" forModifyObjectDictionaryForObject:theObject];
    }
    [self setSubDictionary:nil forKey:@"updateDict" forObject:theObject];
    [self unregisterObject:theObject];
}

- (void)_deleteObject:(id) theObject {
    [self unregisterObject:theObject];
    // Just need to create the dict to mark it for delete
    var deleteDict = [self createSubDictionaryForKey:@"deleteDict" forModifyObjectDictionaryForObject:theObject];
}


/*!
    Remove object from context
 */
- (void)deleteObject:(id) theObject {
    var deleteEvent = [LODeleteEvent deleteEventWithObjects:[theObject] atArrangedObjectIndexes:nil arrayController:nil ownerObjects:nil ownerRelationshipKey:nil];
    [self registerEvent:deleteEvent];
    [self _deleteObject: theObject];
    if (autoCommit) [self saveChanges];
}

/*!
    Remove objects from context
 */
- (void)deleteObjects:(CPArray) theObjects {
    //FIXME: create delete event as in -deleteObject:
    var size = [theObjects count];
    for (var i = 0; i < size; i++) {
        var obj = [theObjects objectAtIndex:i];
        [self _deleteObject:obj];
    }
    if (autoCommit) [self saveChanges];
}

/*!
    Undelete object to context. Used when doing undo
 */
- (void)unDeleteObject:(id) theObject {
    [self _unDeleteObject: theObject];
    if (autoCommit) [self saveChanges];
}

- (void)_unDeleteObject:(id) theObject {
    if ([self subDictionaryForKey:@"deleteDict" forObject:theObject]) {
        [self setSubDictionary:nil forKey:@"deleteDict" forObject:theObject];
    } else {
        [self createSubDictionaryForKey:@"insertDict" forModifyObjectDictionaryForObject:theObject];
    }
    [self registerObject:theObject];
}

/*!
    Undelete objects to context. Used when doing undo
 */
- (void)unDeleteObjects:(CPArray) theObjects {
    var size = [theObjects count];
    for (var i = 0; i < size; i++) {
        var obj = [theObjects objectAtIndex:i];
        [self _unDeleteObject:obj];
    }
    if (autoCommit) [self saveChanges];
}

- (void)_add:(id)newObject toRelationshipWithKey:(CPString)relationshipKey forObject:(id)masterObject {
    //CPLog.trace(@"Added new object " + [newObject className] + @" to master of type " + [masterObject className] + @" for key " + relationshipKey);
    var dictType = [self addRelationshipAsUpdate] || [self isObjectStored:masterObject] ? @"updateDict" : @"insertDict";
    var updateDict = [self createSubDictionaryForKey:dictType forModifyObjectDictionaryForObject:masterObject];
    var relationsShipDict = [updateDict objectForKey:relationshipKey];
    if (!relationsShipDict) {
        relationsShipDict = [CPDictionary dictionary];
        [updateDict setObject:relationsShipDict forKey:relationshipKey];
    }
    var insertsArray = [relationsShipDict objectForKey:@"insert"];
    if (!insertsArray) {
        insertsArray = [CPArray array];
        [relationsShipDict setObject:insertsArray forKey:@"insert"];
    }
    [insertsArray addObject:newObject];
}

/*
    This method will register the newObject as a new to many relationship with the attribute relationshipKey for the master object.
    This method will not register the newObject as a new object in the object context. It has to be done by the insertObject: method.
    This method will not add the newObject to the array of to many relationship objects for the master object. This has to be done by the caller.
 */
- (void)add:(id)newObject toRelationshipWithKey:(CPString)relationshipKey forObject:(id)masterObject {
    //console.log([self className] + " " + _cmd + " " + relationshipKey);
    [self _add:newObject toRelationshipWithKey:relationshipKey forObject:masterObject];
    if (autoCommit) [self saveChanges];
}

- (void)unAdd:(id)newObject toRelationshipWithKey:(CPString)relationshipKey forObject:(id)masterObject {
    [self _unAdd:newObject toRelationshipWithKey:relationshipKey forObject:masterObject];
    if (autoCommit) [self saveChanges];
}

- (void)_unAdd:(id)newObject toRelationshipWithKey:(CPString)relationshipKey forObject:(id)masterObject {
    var dictType = [self isObjectStored:masterObject] ? @"updateDict" : @"insertDict";
    var updateDict = [self createSubDictionaryForKey:dictType forModifyObjectDictionaryForObject:masterObject];
    var relationsShipDict = [updateDict objectForKey:relationshipKey];
    if (relationsShipDict) {
        var insertsArray = [relationsShipDict objectForKey:@"insert"];
        if (insertsArray) {
            [insertsArray removeObject:newObject];
        }
    }
}

- (void)_delete:(id)deletedObject withRelationshipWithKey:(CPString)relationshipKey forObject:(id)masterObject {
    // Right now we do nothing. A delete of the object will be sent and it is enought for one to many relations
    //CPLog.trace(@"Deleted object " + [deletedObject className] + @" for master of type " + [masterObject className] + @" for key " + relationshipKey);
}

- (void)delete:(id)deletedObject withRelationshipWithKey:(CPString)relationshipKey forObject:(id)masterObject {
    [self _delete:deletedObject withRelationshipWithKey:relationshipKey forObject:masterObject];
    if (autoCommit) [self saveChanges];
}

- (void)delete:(id)aMapping withRelationshipWithKey:(CPString)aRelationshipKey between:(id)firstObject and:(id)secondObject {
    //FIXME: raise on index==NSNotFound?
    var leftIndex = [self _findIndexOfObject:aMapping andRemoveItFromRelationshipWithKey:aRelationshipKey ofObject:firstObject];
    var rightIndex = [self _findIndexOfObject:aMapping andRemoveItFromRelationshipWithKey:aRelationshipKey ofObject:secondObject];

    var deleteEvent = [LOManyToManyRelationshipDeleteEvent deleteEventWithMapping:aMapping leftObject:firstObject key:aRelationshipKey index:leftIndex rightObject:secondObject key:aRelationshipKey index:rightIndex];
    [self registerEvent:deleteEvent];

    [self unregisterObject:aMapping];
    [self _deleteObject:aMapping];

    if (autoCommit) [self saveChanges];
}

- (int)_findIndexOfObject:(id)anObject andRemoveItFromRelationshipWithKey:(CPString)aRelationshipKey ofObject:(id)theParent
{
    var array = [theParent valueForKey:aRelationshipKey];
    var index = [array indexOfObjectIdenticalTo:anObject];
    if (index !== CPNotFound) {
        var indexSet = [CPIndexSet indexSetWithIndex:index];
        [theParent willChange:CPKeyValueChangeRemoval valuesAtIndexes:indexSet forKey:aRelationshipKey];
        [array removeObjectAtIndex:index];
        [theParent didChange:CPKeyValueChangeRemoval valuesAtIndexes:indexSet forKey:aRelationshipKey];
    } else if ([array isKindOfClass:[CPArray class]] && [array faultPopulated]) {
        [CPException raise:CPRangeException reason:"Can't find index of " + anObject];
    }

    [self _unAdd:anObject toRelationshipWithKey:aRelationshipKey forObject:theParent];

    return index;
}

- (void)insert:(id)aMapping withRelationshipWithKey:(CPString)aRelationshipKey between:(id)firstObject and:(id)secondObject {
    var leftIndex = [self _findInsertionIndexForObject:aMapping andInsertItIntoRelationshipWithKey:aRelationshipKey ofObject:firstObject];
    var rightIndex = [self _findInsertionIndexForObject:aMapping andInsertItIntoRelationshipWithKey:aRelationshipKey ofObject:secondObject];

    [self _insertObject:aMapping];
    [aMapping setValue:firstObject forKey:[firstObject loObjectType]];
    [aMapping setValue:secondObject forKey:[secondObject loObjectType]];

    var insertEvent = [LOManyToManyRelationshipInsertEvent insertEventWithMapping:aMapping leftObject:firstObject key:aRelationshipKey index:leftIndex  rightObject:secondObject key:aRelationshipKey index:rightIndex];
    [self registerEvent:insertEvent];
}

- (int)_findInsertionIndexForObject:(id)anObject andInsertItIntoRelationshipWithKey:(CPString)aRelationshipKey ofObject:(id)theParent
{
    var array = [theParent valueForKey:aRelationshipKey];
    var index = [array count];
    var indexSet = [CPIndexSet indexSetWithIndex:index];
    [theParent willChange:CPKeyValueChangeInsertion valuesAtIndexes:indexSet forKey:aRelationshipKey];
    [array insertObject:anObject atIndex:index];
    [theParent didChange:CPKeyValueChangeInsertion valuesAtIndexes:indexSet forKey:aRelationshipKey];

    [self _add:anObject toRelationshipWithKey:aRelationshipKey forObject:theParent];

    return index;
}

// TODO: Investigate why this method is implemented 2 times
/*!
   Returns true if the object is already stored on the server side.
 * It does not matter if the object has changes or is deleted in the object context
 *
 */
/*
- (BOOL)isObjectStored:(id)theObject {
    return ![self subDictionaryForKey:@"insertDict" forObject:theObject];
}
/

/*!
   Returns true if the object has unsaved changes for an attrbiute in the object context.
   If the object is deleted all attributes counts as changed.
 */
- (BOOL)isObjectModified:(id)theObject forAttributeKey:(CPString)attributeKey {
    var objDict = [self modifyObjectDictionaryForObject:theObject];
    if (objDict) {
        if ([objDict valueForKey:@"deleteDict"] != nil)
            return YES;
        var updateDict = [objDict valueForKey:@"updateDict"];
        if (updateDict != nil && [updateDict objectForKey:attributeKey] != nil) {
            return YES;
        }
        var insertDict = [objDict valueForKey:@"insertDict"];
        if (insertDict != nil && [insertDict objectForKey:attributeKey] != nil) {
            return YES;
        }
    }

    return NO;
}

/*!
   Returns true if the object has unsaved changes in the object context.
 */
- (BOOL)isObjectModified:(id)theObject {
    var objDict = [self modifyObjectDictionaryForObject:theObject];
    if (objDict) {
        return [objDict valueForKey:@"updateDict"] != nil || [objDict valueForKey:@"insertDict"] != nil || [objDict valueForKey:@"deleteDict"] != nil;
    }

    return NO;
}

/*!
   Returns true if the object is deleted in the object context.
 */
- (BOOL)isObjectDeleted:(id)theObject {
    var objDict = [self modifyObjectDictionaryForObject:theObject];
    if (objDict) {
        return [objDict valueForKey:@"deleteDict"] != nil;
    }

    return NO;
}

/*!
   Returns true if the object context has unsaved changes.
 */
- (BOOL)hasChanges {
    var size = [modifiedObjects count];
    for (var i = 0; i < size; i++) {
        var modifiedObject = [modifiedObjects objectAtIndex:i];
        if (![modifiedObject isEmpty]) {
            return true;
        }
    }
    return false;
}

/*!
   Start a new transaction. All changes will be stored separate from previus changes.
   Transaction must be ended by a saveChanges or revert call.
 */
- (void)startTransaction {
    [undoEvents addObject:[]];
}

- (IBAction)save:(id)sender {
    [self saveChangesWithCompletionHandler:nil];
}

- (IBAction)revert:(id)sender {
    [self revert];
}

/*!
    @deprecated. Use save:(id)sender instead
 */
- (void)saveChanges {
    [self saveChangesWithCompletionHandler:nil];
}

/*!
    Saves the changes in the Object Context.
    It will ask the delegate 'objectContext:shouldSaveChanges:withObject:inserted:' and if
    it returns true it will tell the object store to save the changes.
    A completion block can be provided that is called with the result and statuc code when
    the response is returned.
 */
- (void)saveChangesWithCompletionHandler:(Function)aCompletionBlock {
    if (implementedDelegateMethods & LOObjectContext_objectContext_shouldSaveChanges_withObject_inserted) {
        var shouldSave = YES;
        var size = [modifiedObjects count];
        for (var i = 0; i < size; i++) {
            var modifiedObject = [modifiedObjects objectAtIndex:i];
            if (![modifiedObject isEmpty]) {
                if (![modifiedObject deleteDict]) { // Don't validate if is should be deleted
                    var insertDict = [modifiedObject insertDict];
                    var changesDict = insertDict ? [insertDict mutableCopy] : [CPMutableDictionary dictionary];
                    var updateDict = [modifiedObject updateDict];
                    if (updateDict) {
                        [changesDict addEntriesFromDictionary:updateDict];
                    }
                    shouldSave = [delegate objectContext:self shouldSaveChanges:changesDict withObject:modifiedObject.object inserted:insertDict ? YES : NO];
                    if (!shouldSave) return;
                }
            }
        }
    }

    [objectStore saveChangesWithObjectContext:self withCompletionHandler:aCompletionBlock];

    // Remove transaction
    var count = [undoEvents count];
    if (count) {
        [undoEvents removeObjectAtIndex:count - 1];
    }

    // Remove modifiedObjects
    [self setModifiedObjects:[CPArray array]];
}

/*!
    Should be called by the objectStore when the saveChanges are done
 */
- (void)didSaveChangesWithResult:(id)result andStatus:(int)statusCode withCompletionBlocks:(CPArray)completionBlocks {
    [self callCompletionBlocks:completionBlocks withObject:result andStatus:statusCode];
    if (implementedDelegateMethods & LOObjectContext_objectContext_didSaveChangesWithResultAndStatus) {
        [delegate objectContext:self didSaveChangesWithResult:result andStatus:statusCode];
    }
}

/*!
    @deprecated. Use revert:(id)sender instead
 */
- (void)revert {
//    [self setModifiedObjects:[CPArray array]];

    var lastUndoEvents = [undoEvents lastObject];

    if (lastUndoEvents) {
        var count = [lastUndoEvents count];
        doNotObserveValues = YES;

        while (count--) {
            var event = [lastUndoEvents objectAtIndex:count];
            [event undoForContext:self];
        }
        [undoEvents removeObject:lastUndoEvents];
        doNotObserveValues = NO;
    }
}

/*!
    Private method to get LOModifyRecord for an object
 */
- (id)modifyObjectDictionaryForObject:(id) theObject {
    var size = [modifiedObjects count];
    for (var i = 0; i < size; i++) {
        var objDict = [modifiedObjects objectAtIndex:i];
        var obj = [objDict valueForKey:@"object"];

        if (obj === theObject) {
            return objDict;
        }
    }
    return nil;
}

/*!
    Private method to remove the LOModifyRecord for an object
 */
- (void)removeModifyObjectDictionaryForObject:(id) theObject {
    var size = [modifiedObjects count];
    for (var i = 0; i < size; i++) {
        var objDict = [modifiedObjects objectAtIndex:i];
        var obj = [objDict valueForKey:@"object"];

        if (obj === theObject) {
            [modifiedObjects removeObjectAtIndex:i];
            break;
        }
    }
}

/*!
    Private method to set sub dictionary on LOModifyRecord for an object
 */
- (void)setSubDictionary:(CPDictionary)subDict forKey:(CPString) key forObject:(id) theObject {
    var objDict = [self modifyObjectDictionaryForObject:theObject];
    if (!objDict) {
        if (!subDict) return;       // Bail out if we should set it to nil and we don't have any
        objDict = [LOModifyRecord modifyRecordWithObject:theObject];
        [modifiedObjects addObject:objDict];
    }
    [objDict setValue:subDict forKey:key];
    if ([objDict isEmpty]) {
        [modifiedObjects removeObject:objDict];
    }
}

/*!
    Private method to get sub dictionary on LOModifyRecord for an object
 */
- (CPDictionary)subDictionaryForKey:(CPString)key forObject:(id) theObject {
    var objDict = [self modifyObjectDictionaryForObject:theObject];
    if (objDict) {
        var subDict = [objDict valueForKey:key];
        if (subDict) {
            return subDict;
        }
    }
    return null;
}

/*!
    Private method to get and create sub dictionary on LOModifyRecord for an object.
    This will also create the LOModifiyRecord if it doesn't exists
 */
- (CPDictionary)createSubDictionaryForKey:(CPString) key forModifyObjectDictionaryForObject:(id) theObject {
    var objDict = [self modifyObjectDictionaryForObject:theObject];
    if (!objDict) {
        objDict = [LOModifyRecord modifyRecordWithObject:theObject];
        [modifiedObjects addObject:objDict];
    }
    var subDict = [objDict valueForKey:key];
    if (!subDict) {
        subDict = [CPDictionary dictionary];
        [objDict setValue:subDict forKey:key];
    }
    return subDict;
}

/*!
    Private method to register event. Event is used to undo and rollback changes
 */
- (void)registerEvent:(LOUpdateEvent)updateEvent {
    var lastUndoEvents = [undoEvents lastObject];

    if (!lastUndoEvents) {
        lastUndoEvents = [CPArray array];
        [undoEvents addObject:lastUndoEvents];
    }

    [lastUndoEvents addObject:updateEvent];
}

/*!
    Designated method for triggering a fault.
    If fault is not triggered it will trigger it and call the completion block when result is received.
    If fault is already triggered it will call the completion block directly.
    This is a handy utility when you want to do something on a object. You know that it might be a fault but you don't know if it has triggered.
 */
- (void)triggerFault:(LOFault)fault withRequestId:(id)aRequestId completionHandler:(Function)aCompletionBlock {
    if ([fault conformsToProtocol:@protocol(LOFault)]) {
        [fault requestFaultWithRequestId:aRequestId completionHandler:aCompletionBlock];
    } else {
        aCompletionBlock(fault);
    }
}

/*!
    Convenience method for triggering a fault without specifying a requestId.
 */
- (void)triggerFault:(LOFault)fault withCompletionHandler:(Function)aCompletionBlock {
    [self triggerFault:fault withRequestId:nil completionHandler:aCompletionBlock];
}

@end


@implementation LOObjectContext (Model)

- (CPPropertyDescription)propertyForKey:(CPString)propertyName withObject:(id)anObject {
    return [objectStore propertyForKey:propertyName withEntityNamed:[self typeOfObject:anObject]];
}

- (CPPropertyDescription)propertyForKey:(CPString)propertyName withEntityNamed:(CPString)entityName {
    return [objectStore propertyForKey:propertyName withEntityNamed:entityName];
}

- (CPAttributeDescription)attributeForKey:(CPString)propertyName withEntityNamed:(CPString)entityName {
    return [objectStore attributeForKey:propertyName withEntityNamed:entityName];
}

@end
