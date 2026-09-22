#import "OmRenderSupport.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static OmRenderExceptionHandler OmRenderHandler;

@interface NSApplication (OmRenderSupport)
- (void)om_reportException:(NSException *)exception;
@end

@implementation NSApplication (OmRenderSupport)

- (void)om_reportException:(NSException *)exception {
    NSString *stack = [exception.callStackSymbols componentsJoinedByString:@"\n"];
    if (OmRenderHandler != NULL) {
        OmRenderHandler(exception.name.UTF8String, exception.reason.UTF8String, stack.UTF8String);
    }
    [self om_reportException:exception];
}

@end

void OmInstallRenderExceptionHandler(OmRenderExceptionHandler handler) {
    OmRenderHandler = handler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(NSApplication.class, @selector(reportException:));
        Method replacement = class_getInstanceMethod(NSApplication.class, @selector(om_reportException:));
        method_exchangeImplementations(original, replacement);
    });
}
