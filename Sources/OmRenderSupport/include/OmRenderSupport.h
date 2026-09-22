#import <Foundation/Foundation.h>

typedef void (*OmRenderExceptionHandler)(const char *name, const char *reason, const char *stack);

void OmInstallRenderExceptionHandler(OmRenderExceptionHandler handler);
