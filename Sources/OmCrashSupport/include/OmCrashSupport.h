#import <Foundation/Foundation.h>

typedef void (*OmExceptionHandler)(const char *name, const char *reason, const char *stack);

void OmInstallExceptionHandler(OmExceptionHandler handler);
void OmRaiseTestException(void);
