#import "OmCrashSupport.h"

static OmExceptionHandler OmHandler;

static void OmHandleException(NSException *exception) {
    NSString *stack = [exception.callStackSymbols componentsJoinedByString:@"\n"];
    OmHandler(exception.name.UTF8String, exception.reason.UTF8String, stack.UTF8String);
}

void OmInstallExceptionHandler(OmExceptionHandler handler) {
    OmHandler = handler;
    NSSetUncaughtExceptionHandler(&OmHandleException);
}

void OmRaiseTestException(void) {
    [NSException raise:@"OmSelfTestException" format:@"OM_SELFTEST_CRASH requested exception"];
}
