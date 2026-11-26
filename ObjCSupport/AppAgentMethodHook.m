#import "AppAgentMethodHook.h"
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>
#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>
#define APPAGENT_HOOK_HAS_UIKIT 1
#endif

static NSString *const HookAliasPrefix = @"__appagent_orig_";

static BOOL HookFail(NSError **error, NSString *message) {
    if (error) {
        *error = [NSError errorWithDomain:@"AppAgentMethodHook"
                                     code:1
                                 userInfo:@{
                                     NSLocalizedDescriptionKey: message
                                 }];
    }
    return NO;
}

// MARK: - 类型编码与装箱

static const char *SkipQualifiers(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) {
        type++;
    }
    return type ?: "";
}

static NSUInteger TypeSize(const char *type) {
    NSUInteger size = 0;
    NSGetSizeAndAlignment(type, &size, NULL);
    return size;
}

static NSDictionary *BoxStruct(const void *bytes, const char *type) {
    if (strcmp(type, @encode(CGRect)) == 0) {
        CGRect rect = *(const CGRect *)bytes;
        return @{
            @"x": @(rect.origin.x),
            @"y": @(rect.origin.y),
            @"width": @(rect.size.width),
            @"height": @(rect.size.height)
        };
    }
    if (strcmp(type, @encode(CGPoint)) == 0) {
        CGPoint point = *(const CGPoint *)bytes;
        return @{
            @"x": @(point.x),
            @"y": @(point.y)
        };
    }
    if (strcmp(type, @encode(CGSize)) == 0) {
        CGSize size = *(const CGSize *)bytes;
        return @{
            @"width": @(size.width),
            @"height": @(size.height)
        };
    }
#if APPAGENT_HOOK_HAS_UIKIT
    if (strcmp(type, @encode(UIEdgeInsets)) == 0) {
        UIEdgeInsets insets = *(const UIEdgeInsets *)bytes;
        return @{
            @"top": @(insets.top),
            @"left": @(insets.left),
            @"bottom": @(insets.bottom),
            @"right": @(insets.right)
        };
    }
#endif
    if (strcmp(type, @encode(NSRange)) == 0) {
        NSRange range = *(const NSRange *)bytes;
        return @{
            @"location": @(range.location),
            @"length": @(range.length)
        };
    }
    return nil;
}

/// 按类型编码装箱；不支持的类型返回 nil，由调用方换成 NSNull。
static id BoxValue(const void *bytes, const char *rawType) {
    const char *type = SkipQualifiers(rawType);
    switch (*type) {
        case '@':
        case '#': {
            __unsafe_unretained id object = *(__unsafe_unretained id const *)bytes;
            return object ?: [NSNull null];
        }
        case ':': {
            SEL selector = *(const SEL *)bytes;
            return selector ? NSStringFromSelector(selector) : [NSNull null];
        }
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
        case '{': return BoxStruct(bytes, type);
        default: return nil;
    }
}
static BOOL NumberField(NSDictionary *dictionary, NSString *key, double *out) {
    id value = dictionary[key];
    if (![value isKindOfClass:[NSNumber class]]) {
        return NO;
    }
    *out = [value doubleValue];
    return YES;
}

static NSString *UnboxStruct(id value, const char *type, void *out) {
    if (![value isKindOfClass:[NSDictionary class]]) {
        return @"expects an object with named fields such as x, y, width, height";
    }
    NSDictionary *dictionary = value;
    double a = 0, b = 0, c = 0, d = 0;
    if (strcmp(type, @encode(CGRect)) == 0) {
        if (!NumberField(dictionary, @"x", &a) || !NumberField(dictionary, @"y", &b)
            || !NumberField(dictionary, @"width", &c) || !NumberField(dictionary, @"height", &d)) {
            return @"CGRect needs numeric x, y, width, height";
        }
        *(CGRect *)out = CGRectMake(a, b, c, d);
        return nil;
    }
    if (strcmp(type, @encode(CGPoint)) == 0) {
        if (!NumberField(dictionary, @"x", &a) || !NumberField(dictionary, @"y", &b)) {
            return @"CGPoint needs numeric x, y";
        }
        *(CGPoint *)out = CGPointMake(a, b);
        return nil;
    }
    if (strcmp(type, @encode(CGSize)) == 0) {
        if (!NumberField(dictionary, @"width", &a) || !NumberField(dictionary, @"height", &b)) {
            return @"CGSize needs numeric width, height";
        }
        *(CGSize *)out = CGSizeMake(a, b);
        return nil;
    }
#if APPAGENT_HOOK_HAS_UIKIT
    if (strcmp(type, @encode(UIEdgeInsets)) == 0) {
        if (!NumberField(dictionary, @"top", &a) || !NumberField(dictionary, @"left", &b)
            || !NumberField(dictionary, @"bottom", &c) || !NumberField(dictionary, @"right", &d)) {
            return @"UIEdgeInsets needs numeric top, left, bottom, right";
        }
        *(UIEdgeInsets *)out = UIEdgeInsetsMake(a, b, c, d);
        return nil;
    }
#endif
    if (strcmp(type, @encode(NSRange)) == 0) {
        if (!NumberField(dictionary, @"location", &a) || !NumberField(dictionary, @"length", &b) || a < 0 || b < 0) {
            return @"NSRange needs non-negative location, length";
        }
        *(NSRange *)out = NSMakeRange((NSUInteger)a, (NSUInteger)b);
        return nil;
    }
    return [NSString stringWithFormat:@"unsupported struct type %s", type];
}

static NSString *UnboxNumber(id value, char code, void *out) {
    if (![value isKindOfClass:[NSNumber class]]) {
        return @"expects a number or boolean";
    }
    NSNumber *number = value;
    switch (code) {
        case 'c': *(signed char *)out = number.charValue; break;
        case 'C': *(unsigned char *)out = number.unsignedCharValue; break;
        case 's': *(short *)out = number.shortValue; break;
        case 'S': *(unsigned short *)out = number.unsignedShortValue; break;
        case 'i': *(int *)out = number.intValue; break;
        case 'I': *(unsigned int *)out = number.unsignedIntValue; break;
        case 'l': *(long *)out = number.longValue; break;
        case 'L': *(unsigned long *)out = number.unsignedLongValue; break;
        case 'q': *(long long *)out = number.longLongValue; break;
        case 'Q': *(unsigned long long *)out = number.unsignedLongLongValue; break;
        case 'f': *(float *)out = number.floatValue; break;
        case 'd': *(double *)out = number.doubleValue; break;
        case 'B': *(bool *)out = number.boolValue; break;
        default: return @"unsupported number type";
    }
    return nil;
}

/// 按类型编码把 value 写进 out；返回失败原因，成功返回 nil。对象只写指针，保活由调用方负责。
static NSString *UnboxValue(id value, const char *type, void *out) {
    BOOL isNull = value == nil || value == [NSNull null];
    switch (*type) {
        case '@': {
            *(__unsafe_unretained id *)out = isNull ? nil : value;
            return nil;
        }
        case '#': {
            Class cls = Nil;
            if ([value isKindOfClass:[NSString class]]) {
                cls = NSClassFromString(value);
            } else if (!isNull && object_isClass(value)) {
                cls = value;
            }
            if (!isNull && !cls) {
                return @"expects a class or class name";
            }
            *(__unsafe_unretained Class *)out = cls;
            return nil;
        }
        case ':': {
            if (![value isKindOfClass:[NSString class]]) {
                return @"expects a selector string";
            }
            *(SEL *)out = NSSelectorFromString(value);
            return nil;
        }
        case '{':
            return isNull ? @"struct cannot be null" : UnboxStruct(value, type, out);
        default:
            return isNull ? @"primitive cannot be null" : UnboxNumber(value, *type, out);
    }
}

// MARK: - NSInvocation 读写

static id ArgumentAt(NSInvocation *invocation, NSUInteger index) {
    const char *type = SkipQualifiers([invocation.methodSignature getArgumentTypeAtIndex:index]);
    NSMutableData *buffer = [NSMutableData dataWithLength:MAX(TypeSize(type), sizeof(void *))];
    [invocation getArgument:buffer.mutableBytes atIndex:index];
    return BoxValue(buffer.bytes, type) ?: [NSNull null];
}

static BOOL SetArgumentAt(NSInvocation *invocation, NSUInteger index, id value, NSError **error) {
    const char *type = SkipQualifiers([invocation.methodSignature getArgumentTypeAtIndex:index]);
    NSMutableData *buffer = [NSMutableData dataWithLength:MAX(TypeSize(type), sizeof(void *))];
    NSString *failure = UnboxValue(value, type, buffer.mutableBytes);
    if (failure) {
        return HookFail(error, [NSString stringWithFormat:@"argument %lu %@", (unsigned long)(index - 2), failure]);
    }
    // 先 retainArguments，之后 setArgument 写进去的对象也会被 invocation 持有。
    [invocation retainArguments];
    [invocation setArgument:buffer.mutableBytes atIndex:index];
    return YES;
}

static id ReturnValueOf(NSInvocation *invocation) {
    NSMethodSignature *signature = invocation.methodSignature;
    const char *type = SkipQualifiers(signature.methodReturnType);
    if (*type == 'v' || signature.methodReturnLength == 0) {
        return [NSNull null];
    }
    NSMutableData *buffer = [NSMutableData dataWithLength:MAX(signature.methodReturnLength, sizeof(void *))];
    [invocation getReturnValue:buffer.mutableBytes];
    return BoxValue(buffer.bytes, type) ?: [NSNull null];
}

static BOOL SetReturnValueOf(NSInvocation *invocation, id value, NSError **error) {
    NSMethodSignature *signature = invocation.methodSignature;
    const char *type = SkipQualifiers(signature.methodReturnType);
    if (*type == 'v') {
        return HookFail(error, @"method returns void");
    }
    NSMutableData *buffer = [NSMutableData dataWithLength:MAX(signature.methodReturnLength, sizeof(void *))];
    NSString *failure = UnboxValue(value, type, buffer.mutableBytes);
    if (failure) {
        return HookFail(error, [NSString stringWithFormat:@"return value %@", failure]);
    }
    if (*type == '@' && value && value != [NSNull null]) {
        // 调用方按 +0 接返回值：放进自动释放池，撑到调用方 retain 之后。
        CFAutorelease(CFBridgingRetain(value));
    }
    [invocation setReturnValue:buffer.mutableBytes];
    return YES;
}

static void ZeroReturnValue(NSInvocation *invocation) {
    NSMethodSignature *signature = invocation.methodSignature;
    if (*SkipQualifiers(signature.methodReturnType) == 'v' || signature.methodReturnLength == 0) {
        return;
    }
    NSMutableData *zero = [NSMutableData dataWithLength:signature.methodReturnLength];
    [invocation setReturnValue:zero.mutableBytes];
}

static void InvokeOriginal(NSInvocation *invocation, SEL alias) {
    SEL selector = invocation.selector;
    invocation.selector = alias;
    @try {
        [invocation invoke];
    } @finally {
        invocation.selector = selector;
    }
}
// MARK: - AppAgentHookInvocation

@interface AppAgentHookInvocation ()

- (instancetype)initWithInvocation:(NSInvocation *)invocation
                             alias:(SEL)alias
                              mode:(AppAgentMethodHookMode)mode
                       returnReady:(BOOL)returnReady NS_DESIGNATED_INITIALIZER;

@end

@implementation AppAgentHookInvocation {
    NSInvocation *_invocation;
    SEL _alias;
    AppAgentMethodHookMode _mode;
    // before 模式里原实现还没跑，返回值缓冲区是未初始化内存，按对象读会崩。
    BOOL _returnReady;
}

- (instancetype)initWithInvocation:(NSInvocation *)invocation
                             alias:(SEL)alias
                              mode:(AppAgentMethodHookMode)mode
                       returnReady:(BOOL)returnReady {
    self = [super init];
    if (self) {
        _invocation = invocation;
        _alias = alias;
        _mode = mode;
        _returnReady = returnReady;
    }
    return self;
}

- (id)target {
    return _invocation.target ?: [NSNull null];
}

- (NSArray *)arguments {
    NSUInteger count = _invocation.methodSignature.numberOfArguments;
    NSMutableArray *arguments = [NSMutableArray arrayWithCapacity:count > 2 ? count - 2 : 0];
    for (NSUInteger index = 2; index < count; index++) {
        [arguments addObject:ArgumentAt(_invocation, index)];
    }
    return arguments;
}

- (id)returnValue {
    return _returnReady ? ReturnValueOf(_invocation) : [NSNull null];
}

- (BOOL)setArgument:(id)value atIndex:(NSUInteger)index error:(NSError **)error {
    NSUInteger count = _invocation.methodSignature.numberOfArguments - 2;
    if (index >= count) {
        return HookFail(error, [NSString stringWithFormat:@"argument index %lu out of range (method takes %lu)",
                                (unsigned long)index, (unsigned long)count]);
    }
    return SetArgumentAt(_invocation, index + 2, value, error);
}

- (BOOL)setReturnValue:(id)value error:(NSError **)error {
    if (_mode == AppAgentMethodHookModeBefore) {
        return HookFail(error, @"setReturnValue is not available in before mode");
    }
    if (!SetReturnValueOf(_invocation, value, error)) {
        return NO;
    }
    _returnReady = YES;
    return YES;
}

- (id)invokeOriginalWithError:(NSError **)error {
    if (_mode != AppAgentMethodHookModeInstead) {
        HookFail(error, @"invokeOriginal is only available in instead mode");
        return nil;
    }
    @try {
        InvokeOriginal(_invocation, _alias);
    } @catch (NSException *exception) {
        HookFail(error, exception.reason ?: exception.name);
        return nil;
    }
    _returnReady = YES;
    return ReturnValueOf(_invocation);
}

@end

// MARK: - 注册表

@interface AppAgentHookEntry : NSObject

@property (nonatomic, unsafe_unretained) Class cls;
@property (nonatomic) SEL selector;
@property (nonatomic) SEL alias;
@property (nonatomic) AppAgentMethodHookMode mode;
@property (nonatomic, copy) AppAgentMethodHookHandler handler;
@property (nonatomic) IMP originalIMP;
/// 拦截前 cls 自己没有实现这个方法（继承来的），装的时候补了一份。
@property (nonatomic) BOOL addedMethod;

@end

@implementation AppAgentHookEntry

@end

// 钩子注册表与已替换 forwardInvocation: 的类。锁内只做注册表与 method_setImplementation 这类
// 不会回调宿主代码的操作；查类、查方法（可能触发 +resolveInstanceMethod:）都放在锁外。
static NSRecursiveLock *HookLock(void) {
    static NSRecursiveLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSRecursiveLock new];
    });
    return lock;
}

static NSMutableDictionary<NSValue *, NSMutableDictionary<NSString *, AppAgentHookEntry *> *> *HookEntries(void) {
    static NSMutableDictionary *entries;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        entries = [NSMutableDictionary new];
    });
    return entries;
}

/// 类 → 替换前它自己的 forwardInvocation: 实现（继承来的记 NULL）。
static NSMutableDictionary<NSValue *, NSValue *> *SwizzledForwarders(void) {
    static NSMutableDictionary *forwarders;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        forwarders = [NSMutableDictionary new];
    });
    return forwarders;
}

static NSValue *ClassKey(Class cls) {
    return [NSValue valueWithPointer:(__bridge const void *)cls];
}

static Method DirectMethod(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (sel_isEqual(method_getName(methods[i]), selector)) {
            found = methods[i];
            break;
        }
    }
    free(methods);
    return found;
}

static BOOL IsSameOrSubclass(Class cls, Class ancestor) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        if (current == ancestor) {
            return YES;
        }
    }
    return NO;
}
// MARK: - 转发分发

/// 没有钩子命中时交还给原来的 forwardInvocation:。从接收者的类往上找到第一个被替换过的类，
/// 用它替换前自己的实现；它原本是继承来的就继续往上找。
static IMP FallbackForwarder(Class cls) {
    NSDictionary<NSValue *, NSValue *> *forwarders = SwizzledForwarders();
    BOOL passedSwizzled = NO;
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        NSValue *saved = forwarders[ClassKey(current)];
        if (saved) {
            passedSwizzled = YES;
            IMP previous = (IMP)saved.pointerValue;
            if (previous) {
                return previous;
            }
            continue;
        }
        if (passedSwizzled) {
            Method direct = DirectMethod(current, @selector(forwardInvocation:));
            if (direct) {
                return method_getImplementation(direct);
            }
        }
    }
    return NULL;
}

static void RunHook(AppAgentHookEntry *entry, NSInvocation *invocation) {
    switch (entry.mode) {
        case AppAgentMethodHookModeBefore: {
            entry.handler([[AppAgentHookInvocation alloc] initWithInvocation:invocation
                                                                       alias:entry.alias
                                                                        mode:entry.mode
                                                                 returnReady:NO]);
            InvokeOriginal(invocation, entry.alias);
            break;
        }
        case AppAgentMethodHookModeAfter: {
            InvokeOriginal(invocation, entry.alias);
            entry.handler([[AppAgentHookInvocation alloc] initWithInvocation:invocation
                                                                       alias:entry.alias
                                                                        mode:entry.mode
                                                                 returnReady:YES]);
            break;
        }
        case AppAgentMethodHookModeInstead: {
            // handler 不设返回值时方法返回 0 / nil / 空结构体，而不是未初始化内存。
            ZeroReturnValue(invocation);
            entry.handler([[AppAgentHookInvocation alloc] initWithInvocation:invocation
                                                                       alias:entry.alias
                                                                        mode:entry.mode
                                                                 returnReady:YES]);
            break;
        }
    }
}

static void HookForwardInvocation(__unsafe_unretained id self, SEL _cmd, NSInvocation *invocation) {
    NSString *name = NSStringFromSelector(invocation.selector);
    Class cls = object_getClass(self);
    AppAgentHookEntry *entry = nil;
    IMP fallback = NULL;
    NSRecursiveLock *lock = HookLock();
    [lock lock];
    for (Class current = cls; current && !entry; current = class_getSuperclass(current)) {
        entry = HookEntries()[ClassKey(current)][name];
    }
    if (!entry) {
        fallback = FallbackForwarder(cls);
    }
    [lock unlock];
    if (entry) {
        RunHook(entry, invocation);
        return;
    }
    if (fallback) {
        ((void (*)(id, SEL, NSInvocation *))fallback)(self, _cmd, invocation);
        return;
    }
    [self doesNotRecognizeSelector:invocation.selector];
}

static IMP ForwardingIMP(NSMethodSignature *signature) {
#if defined(__arm64__)
    return (IMP)_objc_msgForward;
#else
    // x86_64 上超过 16 字节的结构体返回走 stret。
    if (*SkipQualifiers(signature.methodReturnType) == '{' && signature.methodReturnLength > 16) {
        return (IMP)_objc_msgForward_stret;
    }
    return (IMP)_objc_msgForward;
#endif
}

static void InstallForwarder(Class cls) {
    NSValue *key = ClassKey(cls);
    if (SwizzledForwarders()[key]) {
        return;
    }
    IMP previous = class_replaceMethod(cls, @selector(forwardInvocation:), (IMP)HookForwardInvocation, "v@:@");
    SwizzledForwarders()[key] = [NSValue valueWithPointer:(const void *)previous];
}

/// ARC 方法家族：去掉前导下划线后以这些词开头，且后面不是小写字母。返回值带所有权，拦截或反射调用都会破坏内存管理。
static BOOL InOwnershipFamily(NSString *selector) {
    NSUInteger start = 0;
    while (start < selector.length && [selector characterAtIndex:start] == '_') {
        start++;
    }
    NSString *rest = [selector substringFromIndex:start];
    for (NSString *family in @[@"alloc", @"new", @"copy", @"mutableCopy", @"init"]) {
        if (![rest hasPrefix:family]) {
            continue;
        }
        if (rest.length == family.length) {
            return YES;
        }
        unichar next = [rest characterAtIndex:family.length];
        if (next < 'a' || next > 'z') {
            return YES;
        }
    }
    return NO;
}

static NSString *HookRejection(NSString *selector) {
    static NSSet<NSString *> *reserved;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        reserved = [NSSet setWithArray:@[
            @"forwardInvocation:", @"methodSignatureForSelector:", @"respondsToSelector:",
            @"retain", @"release", @"autorelease", @"retainCount", @"class", @"dealloc", @".cxx_destruct"
        ]];
    });
    if ([reserved containsObject:selector]) {
        return [NSString stringWithFormat:@"%@ is a runtime method and cannot be hooked", selector];
    }
    if (InOwnershipFamily(selector)) {
        return [NSString stringWithFormat:@"%@ is in the alloc/new/copy/mutableCopy/init family and cannot be hooked", selector];
    }
    return nil;
}
// MARK: - AppAgentMethodHook

@implementation AppAgentMethodHook {
    AppAgentHookEntry *_entry;
}

- (instancetype)initWithEntry:(AppAgentHookEntry *)entry {
    self = [super init];
    if (self) {
        _entry = entry;
    }
    return self;
}

+ (instancetype)hookClassNamed:(NSString *)className
                      selector:(NSString *)selector
                   classMethod:(BOOL)classMethod
                          mode:(AppAgentMethodHookMode)mode
                       handler:(AppAgentMethodHookHandler)handler
                         error:(NSError **)error {
    if (mode != AppAgentMethodHookModeBefore && mode != AppAgentMethodHookModeAfter
        && mode != AppAgentMethodHookModeInstead) {
        HookFail(error, @"unknown hook mode");
        return nil;
    }
    NSString *rejection = HookRejection(selector);
    if (rejection) {
        HookFail(error, rejection);
        return nil;
    }
    Class base = NSClassFromString(className);
    if (!base) {
        HookFail(error, [NSString stringWithFormat:@"class %@ not found", className]);
        return nil;
    }
    Class cls = classMethod ? object_getClass(base) : base;
    SEL sel = NSSelectorFromString(selector);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        HookFail(error, [NSString stringWithFormat:@"%@ has no %@ method %@",
                         className, classMethod ? @"class" : @"instance", selector]);
        return nil;
    }
    const char *types = method_getTypeEncoding(method);
    NSMethodSignature *signature = nil;
    @try {
        signature = [NSMethodSignature signatureWithObjCTypes:types];
    } @catch (NSException *exception) {
        signature = nil;
    }
    if (!signature) {
        HookFail(error, [NSString stringWithFormat:@"%@ has an unsupported signature", selector]);
        return nil;
    }
    SEL alias = NSSelectorFromString([HookAliasPrefix stringByAppendingString:selector]);

    NSRecursiveLock *lock = HookLock();
    [lock lock];
    for (NSMutableDictionary<NSString *, AppAgentHookEntry *> *byName in HookEntries().allValues) {
        AppAgentHookEntry *existing = byName[selector];
        if (existing && (IsSameOrSubclass(cls, existing.cls) || IsSameOrSubclass(existing.cls, cls))) {
            [lock unlock];
            HookFail(error, [NSString stringWithFormat:@"%@ is already hooked on %@ in the same class hierarchy",
                             selector, NSStringFromClass(existing.cls)]);
            return nil;
        }
    }
    Method direct = DirectMethod(cls, sel);
    BOOL added = NO;
    if (!direct) {
        class_addMethod(cls, sel, method_getImplementation(method), types);
        direct = DirectMethod(cls, sel);
        added = YES;
    }
    IMP original = direct ? method_getImplementation(direct) : NULL;
    if (!original || original == (IMP)_objc_msgForward) {
        [lock unlock];
        HookFail(error, [NSString stringWithFormat:@"%@ is already forwarded by another hook mechanism", selector]);
        return nil;
    }
    if (!class_addMethod(cls, alias, original, types)) {
        method_setImplementation(DirectMethod(cls, alias), original);
    }
    InstallForwarder(cls);
    method_setImplementation(direct, ForwardingIMP(signature));

    AppAgentHookEntry *entry = [AppAgentHookEntry new];
    entry.cls = cls;
    entry.selector = sel;
    entry.alias = alias;
    entry.mode = mode;
    entry.handler = handler;
    entry.originalIMP = original;
    entry.addedMethod = added;
    NSValue *key = ClassKey(cls);
    if (!HookEntries()[key]) {
        HookEntries()[key] = [NSMutableDictionary new];
    }
    HookEntries()[key][selector] = entry;
    [lock unlock];
    return [[self alloc] initWithEntry:entry];
}

- (void)remove {
    NSRecursiveLock *lock = HookLock();
    [lock lock];
    AppAgentHookEntry *entry = _entry;
    NSMutableDictionary<NSString *, AppAgentHookEntry *> *byName = HookEntries()[ClassKey(entry.cls)];
    NSString *name = NSStringFromSelector(entry.selector);
    if (byName[name] != entry) {
        [lock unlock];
        return;
    }
    [byName removeObjectForKey:name];
    IMP restored = entry.originalIMP;
    if (entry.addedMethod) {
        // 补上去的那份方法删不掉，改回指向父类当前的实现。
        Class superclass = class_getSuperclass(entry.cls);
        Method inherited = superclass ? class_getInstanceMethod(superclass, entry.selector) : NULL;
        if (inherited) {
            restored = method_getImplementation(inherited);
        }
    }
    Method direct = DirectMethod(entry.cls, entry.selector);
    if (direct) {
        method_setImplementation(direct, restored);
    }
    [lock unlock];
}

+ (id)invokeTarget:(id)target selector:(NSString *)selector arguments:(NSArray *)arguments error:(NSError **)error {
    if (!target || target == [NSNull null]) {
        HookFail(error, @"target is null");
        return nil;
    }
    if (InOwnershipFamily(selector)
        || [@[@"dealloc", @"retain", @"release", @"autorelease"] containsObject:selector]) {
        HookFail(error, [NSString stringWithFormat:@"%@ manages object ownership and cannot be called; use newObject", selector]);
        return nil;
    }
    SEL sel = NSSelectorFromString(selector);
    NSMethodSignature *signature = nil;
    @try {
        if ([target respondsToSelector:sel]) {
            signature = [target methodSignatureForSelector:sel];
        }
    } @catch (NSException *exception) {
        signature = nil;
    }
    if (!signature) {
        HookFail(error, [NSString stringWithFormat:@"%@ does not respond to %@",
                         object_isClass(target) ? NSStringFromClass(target) : NSStringFromClass([target class]), selector]);
        return nil;
    }
    NSUInteger expected = signature.numberOfArguments - 2;
    if (arguments.count != expected) {
        HookFail(error, [NSString stringWithFormat:@"%@ takes %lu arguments, got %lu",
                         selector, (unsigned long)expected, (unsigned long)arguments.count]);
        return nil;
    }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = sel;
    [invocation retainArguments];
    for (NSUInteger index = 0; index < expected; index++) {
        if (!SetArgumentAt(invocation, index + 2, arguments[index], error)) {
            return nil;
        }
    }
    @try {
        [invocation invoke];
    } @catch (NSException *exception) {
        HookFail(error, exception.reason ?: exception.name);
        return nil;
    }
    return ReturnValueOf(invocation);
}

+ (id)newObjectOfClassNamed:(NSString *)className error:(NSError **)error {
    Class cls = NSClassFromString(className);
    if (!cls) {
        HookFail(error, [NSString stringWithFormat:@"class %@ not found", className]);
        return nil;
    }
    @try {
        id object = [[cls alloc] init];
        if (!object) {
            HookFail(error, [NSString stringWithFormat:@"[[%@ alloc] init] returned nil", className]);
        }
        return object;
    } @catch (NSException *exception) {
        HookFail(error, exception.reason ?: exception.name);
        return nil;
    }
}

@end
