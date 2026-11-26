#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 拦截时机：before 先跑 handler 再跑原实现；after 反过来；instead 只跑 handler，
/// handler 需要原实现时自己调 `invokeOriginal`。
typedef NS_ENUM(NSInteger, AppAgentMethodHookMode) {
    AppAgentMethodHookModeBefore = 0,
    AppAgentMethodHookModeAfter = 1,
    AppAgentMethodHookModeInstead = 2,
};

/// 一次被拦截的调用。参数和返回值都按类型编码装箱：对象原样（nil 用 NSNull），
/// 整数 / 浮点 / BOOL 为 NSNumber，SEL 为 NSString，CGRect / CGPoint / CGSize /
/// UIEdgeInsets / NSRange 为字段名同结构体的 NSDictionary。不支持的类型读出来是 NSNull，写入报错。
@interface AppAgentHookInvocation : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// 接收者：实例方法是对象，类方法是 Class。
@property (nonatomic, readonly) id target;

/// 参数（不含 self / _cmd），下标从 0 开始。
@property (nonatomic, readonly) NSArray *arguments;

/// 当前返回值；void 方法或 nil 返回 NSNull。
@property (nonatomic, readonly) id returnValue;

- (BOOL)setArgument:(nullable id)value atIndex:(NSUInteger)index error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(setArgument(_:at:));

/// before 模式下原实现还没跑、返回值会被覆盖，所以拒绝。
- (BOOL)setReturnValue:(nullable id)value error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(setReturnValue(_:));

/// 执行原实现，返回装箱后的返回值（void / nil 为 NSNull）。只有 instead 模式可用。
- (nullable id)invokeOriginalWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(invokeOriginal());

@end

typedef void (^AppAgentMethodHookHandler)(AppAgentHookInvocation *invocation);

/// 基于消息转发的方法拦截（与 Aspects 同一思路）：被拦截的方法改指向 `_objc_msgForward`，
/// 类的 `forwardInvocation:` 换成分发函数，原实现挂在别名选择子上。
/// 同一个选择子在一条继承链上只能拦一层；`remove` 恢复原实现。线程安全；handler 在调用方线程执行。
@interface AppAgentMethodHook : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// 拦截 `className` 的实例方法（`classMethod` 为 YES 时是类方法）。
/// Swift 类写成「模块名.类名」，方法须是 @objc dynamic。
/// alloc / new / copy / mutableCopy / init / dealloc 家族与运行时基础方法拒绝拦截。
+ (nullable instancetype)hookClassNamed:(NSString *)className
                               selector:(NSString *)selector
                            classMethod:(BOOL)classMethod
                                   mode:(AppAgentMethodHookMode)mode
                                handler:(AppAgentMethodHookHandler)handler
                                  error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(install(className:selector:classMethod:mode:handler:));

/// 恢复原实现。可重复调用。
- (void)remove;

/// 反射调用：`target` 是对象或 Class（调类方法）。参数按方法签名拆箱；返回装箱后的值（void / nil 为 NSNull）。
/// 返回带所有权的方法（alloc / new / copy / mutableCopy / init 家族）拒绝调用，建对象用 `newObjectOfClassNamed:`。
+ (nullable id)invokeTarget:(id)target
                   selector:(NSString *)selector
                  arguments:(NSArray *)arguments
                      error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(invoke(target:selector:arguments:));

/// `[[Class alloc] init]`。
+ (nullable id)newObjectOfClassNamed:(NSString *)className error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(newObject(className:));

@end

NS_ASSUME_NONNULL_END
