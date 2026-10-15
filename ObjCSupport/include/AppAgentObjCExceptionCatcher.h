#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges Objective-C `@try/@catch` into Swift so runtime-inspection tools
/// (KVC read/write, reflection invoke) can surface NSExceptions as Swift
/// errors instead of crashing the host app.
@interface AppAgentObjCExceptionCatcher : NSObject

/// Runs `tryBlock`. Returns YES on success; on a raised NSException returns NO
/// and populates `error` with the exception's reason.
+ (BOOL)catchException:(NS_NOESCAPE void (^)(void))tryBlock
                 error:(NSError * _Nullable * _Nullable)error;

/// Read a declared property/getter or ivar without KVC's method-name guessing.
/// `allowGetter` is reserved for getters explicitly allowed by the caller.
/// Raises NSException for unsupported reads; call inside catchException.
+ (nullable id)readDeclaredValueFrom:(id)target key:(NSString *)key allowGetter:(BOOL)allowGetter
    NS_SWIFT_NAME(readDeclaredValue(from:key:allowGetter:));

@end

NS_ASSUME_NONNULL_END
