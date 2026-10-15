#import "AppAgentObjCExceptionCatcher.h"
#import <objc/runtime.h>

static void RejectPropertyRead(void) {
    [NSException raise:NSInvalidArgumentException format:@"Unsupported property read"];
}

static const char *ReadableType(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) {
        type++;
    }
    if (!type || !*type || !strchr("@cCsSiIlLqQfdB{", *type) || strcmp(type, "@?") == 0) {
        RejectPropertyRead();
    }
    return type;
}

static id BoxPropertyBytes(const void *bytes, const char *type) {
    switch (*type) {
        case '@': return *(__unsafe_unretained id const *)bytes;
        case 'c': return @(*(const signed char *)bytes);
        case 'C': return @(*(const unsigned char *)bytes);
        case 's': return @(*(const short *)bytes);
        case 'S': return @(*(const unsigned short *)bytes);
        case 'i': return @(*(const int *)bytes);
        case 'I': return @(*(const unsigned int *)bytes);
        case 'l': return @(*(const long *)bytes);
        case 'L': return @(*(const unsigned long *)bytes);
        case 'q': return @(*(const long long *)bytes);
        case 'Q': return @(*(const unsigned long long *)bytes);
        case 'f': return @(*(const float *)bytes);
        case 'd': return @(*(const double *)bytes);
        case 'B': return @(*(const bool *)bytes);
        default: return [NSValue valueWithBytes:bytes objCType:type];
    }
}

static NSString *PropertyGetter(objc_property_t property) {
    char *custom = property_copyAttributeValue(property, "G");
    NSString *getter = custom ? @(custom) : @(property_getName(property));
    free(custom);
    return getter;
}

// Metadata-only lookup: do not ask the object to resolve/forward an unknown selector.
static Method ExistingMethod(Class cls, SEL selector) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        Method found = NULL;
        for (unsigned int i = 0; i < count; i++) {
            if (sel_isEqual(method_getName(methods[i]), selector)) {
                found = methods[i];
                break;
            }
        }
        free(methods);
        if (found) {
            return found;
        }
    }
    return NULL;
}

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

+ (id)readDeclaredValueFrom:(id)target key:(NSString *)key allowGetter:(BOOL)allowGetter {
    Class cls = object_getClass(target);
    if (!cls || key.length == 0) {
        RejectPropertyRead();
    }
    objc_property_t property = class_getProperty(cls, key.UTF8String);
    NSString *getter = property ? PropertyGetter(property) : nil;
    // Accept a declared custom getter too (e.g. hidden / isHidden).
    for (Class current = cls; !getter && current; current = class_getSuperclass(current)) {
        unsigned int count = 0;
        objc_property_t *properties = class_copyPropertyList(current, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *candidate = PropertyGetter(properties[i]);
            if ([candidate isEqualToString:key]) {
                getter = candidate;
                break;
            }
        }
        free(properties);
    }
    if (!getter && allowGetter) {
        getter = key;
    }
    if (getter) {
        SEL selector = NSSelectorFromString(getter);
        Method method = ExistingMethod(cls, selector);
        if (!method || method_getNumberOfArguments(method) != 2) {
            RejectPropertyRead();
        }
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        const char *type = ReadableType(signature.methodReturnType);
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = target;
        invocation.selector = selector;
        NSMutableData *storage = [NSMutableData dataWithLength:signature.methodReturnLength];
        [invocation invoke];
        [invocation getReturnValue:storage.mutableBytes];
        return BoxPropertyBytes(storage.bytes, type);
    }
    // An ivar is read directly: a same-named method must never take precedence.
    NSString *capitalized = [[key substringToIndex:1].uppercaseString stringByAppendingString:[key substringFromIndex:1]];
    NSArray<NSString *> *names = @[
        [@"_" stringByAppendingString:key], [@"_is" stringByAppendingString:capitalized],
        key, [@"is" stringByAppendingString:capitalized]
    ];
    Ivar ivar = NULL;
    if (!class_isMetaClass(cls)) {
        for (NSString *name in names) {
            ivar = class_getInstanceVariable(cls, name.UTF8String);
            if (ivar) {
                break;
            }
        }
    }
    if (!ivar || ![cls accessInstanceVariablesDirectly]) {
        RejectPropertyRead();
    }
    const char *type = ReadableType(ivar_getTypeEncoding(ivar));
    if (*type == '@') {
        return object_getIvar(target, ivar);
    }
    NSUInteger size = 0;
    NSGetSizeAndAlignment(type, &size, NULL);
    ptrdiff_t offset = ivar_getOffset(ivar);
    size_t instanceSize = class_getInstanceSize(cls);
    if (offset < 0 || (size_t)offset > instanceSize || size > instanceSize - (size_t)offset) {
        RejectPropertyRead();
    }
    return BoxPropertyBytes((const char *)(__bridge const void *)target + offset, type);
}

@end
