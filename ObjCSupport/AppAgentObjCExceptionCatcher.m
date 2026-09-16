#import "AppAgentObjCExceptionCatcher.h"

@implementation AppAgentObjCExceptionCatcher

+ (BOOL)catchException:(NS_NOESCAPE void (^)(void))tryBlock
                 error:(NSError * _Nullable * _Nullable)error {
    @try {
        tryBlock();
        return YES;
    }
    @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: exception.name ?: @"Objective-C exception";
            *error = [NSError errorWithDomain:@"AppAgentObjCException"
                                         code:0
                                     userInfo:@{ NSLocalizedDescriptionKey: reason }];
        }
        return NO;
    }
}

@end
